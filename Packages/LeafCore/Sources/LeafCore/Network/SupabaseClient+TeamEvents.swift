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

  /// Send auto-shared team event — JWT-bearing INSERT via PostgREST.
  /// Sender pubkey is taken from JWT claim; RLS WITH CHECK enforces match.
  /// `expiresAt` populated by caller (broadcast service: now + 30 days).
  public func sendTeamEvent(
    workspaceID: String,
    eventID: String,
    sourceKind: String,
    kind: String,
    encryptedPayload: Data,
    expiresAt: Date
  ) async throws -> SupabaseSentTeamEventRow {
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.teamEventsInsert(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // C4 Stage 6 review fix — merge-duplicates header so transient
    // network failures that cause client retry with the same
    // deterministic event_id don't double-insert (PostgREST returns
    // 200/201 echoing the existing row instead of 409).
    for (k, v) in SupabaseEndpoint.postgrestInsertHeadersIgnoreDuplicates(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    guard let senderPubkeyHex = session.pubkeyClaim, !senderPubkeyHex.isEmpty else {
      throw SupabaseError.identityClaimMissing
    }
    let payloadHex = "\\x" + encryptedPayload.map { String(format: "%02x", $0) }.joined()
    let iso = Self.iso8601Formatter().string(from: expiresAt)
    let body: [String: Any] = [
      "event_id": eventID,
      "workspace_id": workspaceID,
      "sender_pubkey": senderPubkeyHex,
      "source_kind": sourceKind,
      "kind": kind,
      "encrypted_payload": payloadHex,
      "expires_at": iso,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await teamEventsTransport(
      request, label: "sendTeamEvent", retryable: false)
    // C4: with resolution=merge-duplicates, PostgREST returns 200 (not
    // 201) when the row already exists. Both are success in our retry
    // path — server has the row, client moves on.
    guard response.statusCode == 200 || response.statusCode == 201 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    struct Row: Decodable {
      let event_id: String
      let created_at: String
    }
    let rows: [Row]
    do {
      rows = try JSONDecoder().decode([Row].self, from: data)
    } catch {
      throw SupabaseError.decoding(reason: "sendTeamEvent: \(error)")
    }
    guard let first = rows.first else {
      throw SupabaseError.decoding(reason: "sendTeamEvent: empty rows")
    }
    return SupabaseSentTeamEventRow(eventID: first.event_id, createdAtISO: first.created_at)
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
      request, label: "fetchInboundTeamEvents", retryable: true)
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
    retryable: Bool = false
  ) async throws -> (Data, HTTPURLResponse) {
    try await performHTTP(request, retryable: retryable, label: label)
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
