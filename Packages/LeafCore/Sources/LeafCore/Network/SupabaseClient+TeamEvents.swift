//
//  SupabaseClient+TeamEvents.swift
//  LeafCore
//
//  Track 5 / S5 — Auto-share broadcast + recipient mirror wire layer.
//  POST inserts under JWT pubkey claim (RLS gates sender = JWT pubkey).
//  GET reads workspace-scoped feed (RLS gates workspace_member access).
//  expires_at is populated by sender (30 days per Track 5 contract §13);
//  server-side retention_purge cron deletes expired rows.
//

import Foundation

// MARK: - Wire response shapes

public struct SupabaseSentTeamEventRow: Sendable, Equatable {
  public let eventID: String
  public let createdAtISO: String

  public init(eventID: String, createdAtISO: String) {
    self.eventID = eventID
    self.createdAtISO = createdAtISO
  }
}

public struct SupabaseTeamEventRow: Sendable, Equatable {
  public let eventID: String
  public let workspaceID: String
  public let senderPubkeyHex: String
  public let sourceKind: String
  public let kind: String
  public let encryptedPayload: Data
  public let createdAtISO: String
  public let createdAtMs: Int64
  public let expiresAtISO: String?

  public init(
    eventID: String,
    workspaceID: String,
    senderPubkeyHex: String,
    sourceKind: String,
    kind: String,
    encryptedPayload: Data,
    createdAtISO: String,
    createdAtMs: Int64,
    expiresAtISO: String?
  ) {
    self.eventID = eventID
    self.workspaceID = workspaceID
    self.senderPubkeyHex = senderPubkeyHex
    self.sourceKind = sourceKind
    self.kind = kind
    self.encryptedPayload = encryptedPayload
    self.createdAtISO = createdAtISO
    self.createdAtMs = createdAtMs
    self.expiresAtISO = expiresAtISO
  }
}

// MARK: - TeamEvent methods

extension SupabaseClient {

  /// Send auto-shared team event via `send_team_event` Edge Function (M-II).
  /// Idempotent — Idempotency-Key dedup on server makes retries safe.
  ///
  /// `eventID` is accepted for API compatibility with existing callers
  /// (TeamEventBroadcastService passes a deterministic UUID); it is included
  /// in the idempotency body hash via `created_at_ms` but NOT sent as a body
  /// field — the Edge Function generates its own server-side event_id UUID.
  /// The returned `SupabaseSentTeamEventRow.eventID` carries the server-generated
  /// value.
  ///
  /// `encrypted_payload` MUST be PostgreSQL bytea hex `\x<hex>` format — the
  /// Edge Function rejects base64. The existing `\x` encoding produced by the
  /// caller is preserved unchanged.
  ///
  /// `source_kind` is required (no DB DEFAULT after S5 migration).
  public func sendTeamEvent(
    workspaceID: String,
    eventID: String,
    sourceKind: String,
    kind: String,
    encryptedPayload: Data,
    expiresAt: Date
  ) async throws -> SupabaseSentTeamEventRow {
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.sendTeamEventEdge(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.authenticatedHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    // Preserve the existing PostgreSQL bytea hex wire format (\x<hex>).
    // The Edge Function validates this exact format and rejects base64.
    let payloadHex = "\\x" + encryptedPayload.map { String(format: "%02x", $0) }.joined()
    let expiresAtISO = Self.iso8601Formatter().string(from: expiresAt)
    let createdAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    // Note: `event_id` (caller's deterministic UUID) is intentionally excluded
    // from the Edge body — server generates its own PK. `created_at_ms` anchors
    // the idempotency key hash so same-tick retries deduplicate correctly.
    _ = eventID  // kept in signature for API compatibility; not sent to Edge
    let body: [String: Any] = [
      "workspace_id": workspaceID,
      "kind": kind,
      "source_kind": sourceKind,
      "encrypted_payload": payloadHex,
      "expires_at": expiresAtISO,
      "created_at_ms": createdAtMs,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await teamEventsTransport(
      request, label: "sendTeamEvent", retryable: true, refreshable: true,
      idempotent: true)
    guard response.statusCode == 201 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    // Edge response: { event_id, workspace_id, created_at (ISO 8601) }.
    struct EdgeRow: Decodable {
      let event_id: String
      let created_at: String
    }
    let row: EdgeRow
    do {
      row = try JSONDecoder().decode(EdgeRow.self, from: data)
    } catch {
      throw SupabaseError.decoding(reason: "sendTeamEvent: \(error)")
    }
    return SupabaseSentTeamEventRow(eventID: row.event_id, createdAtISO: row.created_at)
  }

  /// Fetch inbound team events — workspace-scoped GET via PostgREST.
  /// Caller passes since watermark in ms; converted to ISO for the `gt.<iso>` filter.
  /// `nil` watermark = cold bootstrap (returns oldest 100 rows).
  public func fetchInboundTeamEvents(
    workspaceID: String,
    sinceCreatedAtMs: Int64?,
    limit: Int = 100
  ) async throws -> [SupabaseTeamEventRow] {
    let sinceISO: String? = sinceCreatedAtMs.map {
      Self.iso8601Formatter().string(from: Date(timeIntervalSince1970: TimeInterval($0) / 1000.0))
    }
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.teamEventsFetchInbound(
      baseURL: baseURL,
      workspaceID: workspaceID,
      sinceCreatedAtISO: sinceISO,
      limit: limit
    )
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    for (k, v) in SupabaseEndpoint.authenticatedHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }

    let (data, response) = try await teamEventsTransport(
      request, label: "fetchInboundTeamEvents", retryable: true, refreshable: true)
    guard response.statusCode == 200 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    struct Row: Decodable {
      let event_id: String
      let workspace_id: String
      let sender_pubkey: String
      let source_kind: String
      let kind: String
      let encrypted_payload: String
      let created_at: String
      let expires_at: String?
    }
    let rows: [Row]
    do {
      rows = try JSONDecoder().decode([Row].self, from: data)
    } catch {
      throw SupabaseError.decoding(reason: "fetchInboundTeamEvents: \(error)")
    }
    return rows.map { r in
      SupabaseTeamEventRow(
        eventID: r.event_id,
        workspaceID: r.workspace_id,
        senderPubkeyHex: r.sender_pubkey,
        sourceKind: r.source_kind,
        kind: r.kind,
        encryptedPayload: Self.decodeByteaHex(r.encrypted_payload),
        createdAtISO: r.created_at,
        createdAtMs: Self.iso8601ToMs(r.created_at),
        expiresAtISO: r.expires_at
      )
    }
  }

  // MARK: - Helpers (local to S5; do not leak across files)

  private func teamEventsTransport(
    _ request: URLRequest,
    label: String,
    retryable: Bool = false,
    refreshable: Bool = false,
    idempotent: Bool = false
  ) async throws -> (Data, HTTPURLResponse) {
    try await performHTTP(
      request, retryable: retryable, refreshable: refreshable, idempotent: idempotent, label: label)
  }

  /// Build a fresh ISO8601 formatter per call — ISO8601DateFormatter is
  /// not Sendable, so keeping it as a static let would require `nonisolated(unsafe)`
  /// gymnastics. Construction cost is negligible at S5 broadcast frequency.
  private static func iso8601Formatter() -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }

  /// Convert PostgreSQL `\x<hex>` bytea representation to Data. Same logic as
  /// SupabaseClient+DirectMessages.decodePostgresByteaHex — kept local to
  /// avoid cross-extension dependencies (precedent for code duplication
  /// noted as carry-over for Track 6 consolidation).
  private static func decodeByteaHex(_ s: String) -> Data {
    var hex = s
    if hex.hasPrefix("\\x") {
      hex = String(hex.dropFirst(2))
    }
    while hex.first == "\\" || hex.first == "x" {
      hex = String(hex.dropFirst())
    }
    var bytes = Data()
    var idx = hex.startIndex
    while idx < hex.endIndex {
      let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
      let pair = String(hex[idx..<next])
      if let byte = UInt8(pair, radix: 16) {
        bytes.append(byte)
      }
      idx = next
    }
    return bytes
  }

  private static func iso8601ToMs(_ iso: String) -> Int64 {
    if let date = iso8601Formatter().date(from: iso) {
      return Int64(date.timeIntervalSince1970 * 1000)
    }
    // Fallback formatter without fractional seconds (older Supabase rows).
    let fb = ISO8601DateFormatter()
    fb.formatOptions = [.withInternetDateTime]
    if let date = fb.date(from: iso) {
      return Int64(date.timeIntervalSince1970 * 1000)
    }
    return 0
  }
}
