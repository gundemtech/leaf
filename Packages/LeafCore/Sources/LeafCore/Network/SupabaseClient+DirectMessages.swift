//
//  SupabaseClient+DirectMessages.swift
//  LeafCore
//
//  Track 5 / S4 — DM + APNs network surface. All methods rely on the actor's
//  existing `ensureAuthenticated` bootstrap (which now picks up the persisted
//  refresh_token via SupabaseSessionStore). JWT carries `pubkey` claim used by
//  RLS to gate INSERT (sender = JWT pubkey) and UPDATE (sender OR recipient).
//

import Foundation

// MARK: - Wire response shapes

public struct SupabaseSentMessageRow: Sendable, Equatable {
  public let messageID: String
  public let createdAtISO: String

  public init(messageID: String, createdAtISO: String) {
    self.messageID = messageID
    self.createdAtISO = createdAtISO
  }
}

public struct SupabaseDirectMessageRow: Sendable, Equatable {
  public let messageID: String
  public let workspaceID: String
  public let senderPubkeyHex: String
  public let recipientPubkeyHex: String
  public let kind: String
  public let encryptedPayload: Data
  public let crossPostJSON: String?
  public let createdAtISO: String
  public let readAtISO: String?
  public let doneAtISO: String?
  public let doneByPubkeyHex: String?
  public let replyTo: String?

  public init(
    messageID: String,
    workspaceID: String,
    senderPubkeyHex: String,
    recipientPubkeyHex: String,
    kind: String,
    encryptedPayload: Data,
    crossPostJSON: String?,
    createdAtISO: String,
    readAtISO: String?,
    doneAtISO: String?,
    doneByPubkeyHex: String?,
    replyTo: String?
  ) {
    self.messageID = messageID
    self.workspaceID = workspaceID
    self.senderPubkeyHex = senderPubkeyHex
    self.recipientPubkeyHex = recipientPubkeyHex
    self.kind = kind
    self.encryptedPayload = encryptedPayload
    self.crossPostJSON = crossPostJSON
    self.createdAtISO = createdAtISO
    self.readAtISO = readAtISO
    self.doneAtISO = doneAtISO
    self.doneByPubkeyHex = doneByPubkeyHex
    self.replyTo = replyTo
  }
}

public struct SupabaseAPNsPushResult: Sendable, Equatable {
  public let devicesPushed: Int
  public let errors: [APNsPushDeviceError]
  /// Track 5 / S8 / T5 — true when the Edge Function declined to push
  /// because the recipient's `notification_prefs` row for the message
  /// kind has `enabled=false`. devicesPushed will be 0; no errors row.
  /// Surfaced for client-side telemetry / dev logs only — sender treats
  /// this as a successful no-op (recipient opted out, that's the
  /// expected outcome).
  public let skippedByPrefs: Bool

  public struct APNsPushDeviceError: Sendable, Equatable {
    public let deviceID: String
    public let status: Int
    public let reason: String?

    public init(deviceID: String, status: Int, reason: String?) {
      self.deviceID = deviceID
      self.status = status
      self.reason = reason
    }
  }

  public init(
    devicesPushed: Int,
    errors: [APNsPushDeviceError],
    skippedByPrefs: Bool = false
  ) {
    self.devicesPushed = devicesPushed
    self.errors = errors
    self.skippedByPrefs = skippedByPrefs
  }
}

// MARK: - DM methods

extension SupabaseClient {

  /// Send direct message — JWT-bearing INSERT via PostgREST.
  /// Encrypts `encryptedPayload` to PostgreSQL bytea hex (`\\x<hex>`) on the wire.
  /// Returns `(messageID, createdAt)` from PostgREST's `return=representation`.
  public func sendDirectMessage(
    workspaceID: String,
    recipientPubkeyHex: String,
    kind: DirectMessageKind,
    encryptedPayload: Data,
    replyTo: String?
  ) async throws -> SupabaseSentMessageRow {
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.directMessagesInsert(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.postgrestInsertHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let payloadHex = "\\x" + encryptedPayload.map { String(format: "%02x", $0) }.joined()
    // I1+I2 — Track 5 / S4 Stage 6 review fix:
    // We send sender_pubkey explicitly to satisfy the NOT NULL column.
    // Server-side RLS WITH CHECK verifies the body's sender_pubkey matches
    // the JWT pubkey claim (auth.jwt() ->> 'pubkey'). If pubkeyClaim is nil
    // — Auth Hook race, JWT decode glitch — fail fast with a clear error
    // rather than POST an empty string (which would surface as opaque 403).
    guard let senderPubkeyHex = session.pubkeyClaim, !senderPubkeyHex.isEmpty else {
      throw SupabaseError.identityClaimMissing
    }
    var body: [String: Any] = [
      "workspace_id": workspaceID,
      "sender_pubkey": senderPubkeyHex,
      "recipient_pubkey": recipientPubkeyHex,
      "kind": kind.rawValue,
      "encrypted_payload": payloadHex,
    ]
    if let replyTo {
      body["reply_to"] = replyTo
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await transport(
      request, label: "sendDirectMessage", retryable: false, refreshable: true)
    guard response.statusCode == 201 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    struct Row: Decodable {
      let message_id: String
      let created_at: String
    }
    let rows: [Row]
    do {
      rows = try JSONDecoder().decode([Row].self, from: data)
    } catch {
      throw SupabaseError.decoding(reason: "sendDirectMessage: \(error)")
    }
    guard let first = rows.first else {
      throw SupabaseError.decoding(reason: "sendDirectMessage: empty rows")
    }
    return SupabaseSentMessageRow(
      messageID: first.message_id, createdAtISO: first.created_at
    )
  }

  /// Fetch inbound direct messages — GET via PostgREST filter on workspace + recipient.
  /// Caller passes sinceCreatedAtISO for incremental sync (`nil` = cold bootstrap).
  public func fetchInboundMessages(
    workspaceID: String,
    recipientPubkeyHex: String,
    sinceCreatedAtISO: String?,
    limit: Int = 100
  ) async throws -> [SupabaseDirectMessageRow] {
    try await fetchMessages(
      url: SupabaseEndpoint.directMessagesFetchInbound(
        baseURL: baseURL,
        workspaceID: workspaceID,
        recipientPubkeyHex: recipientPubkeyHex,
        sinceCreatedAtISO: sinceCreatedAtISO,
        limit: limit
      ),
      label: "fetchInboundMessages"
    )
  }

  /// Fetch outbound direct messages — multi-device sync (own sender row reads).
  public func fetchOutboundMessages(
    workspaceID: String,
    senderPubkeyHex: String,
    sinceCreatedAtISO: String?,
    limit: Int = 100
  ) async throws -> [SupabaseDirectMessageRow] {
    try await fetchMessages(
      url: SupabaseEndpoint.directMessagesFetchOutbound(
        baseURL: baseURL,
        workspaceID: workspaceID,
        senderPubkeyHex: senderPubkeyHex,
        sinceCreatedAtISO: sinceCreatedAtISO,
        limit: limit
      ),
      label: "fetchOutboundMessages"
    )
  }

  /// I5 fix — Track 5 / S4 Stage 6 review: targeted single-row fetch for
  /// APNs-wake path. fetchInboundMessages with a 100-row cap could miss the
  /// target message if many newer rows exist; this direct query never misses.
  public func fetchMessageByID(messageID: String) async throws -> SupabaseDirectMessageRow? {
    let rows = try await fetchMessages(
      url: SupabaseEndpoint.directMessagesFetchByID(baseURL: baseURL, messageID: messageID),
      label: "fetchMessageByID"
    )
    return rows.first
  }

  private func fetchMessages(url: URL, label: String) async throws -> [SupabaseDirectMessageRow] {
    let session = try await ensureAuthenticated()
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    for (k, v) in SupabaseEndpoint.authenticatedHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }

    let (data, response) = try await transport(
      request, label: label, retryable: true, refreshable: true)
    guard response.statusCode == 200 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    struct Row: Decodable {
      let message_id: String
      let workspace_id: String
      let sender_pubkey: String
      let recipient_pubkey: String
      let kind: String
      let encrypted_payload: String  // PostgREST bytea hex `\x<hex>`
      let cross_post: TolerantCrossPostJSON?  // TEXT, JSONB object, or null
      let created_at: String
      let read_at: String?
      let done_at: String?
      let done_by_pubkey: String?
      let reply_to: String?
    }
    let rows: [Row]
    do {
      rows = try JSONDecoder().decode([Row].self, from: data)
    } catch {
      throw SupabaseError.decoding(reason: "\(label): \(error)")
    }
    return rows.map { r in
      SupabaseDirectMessageRow(
        messageID: r.message_id,
        workspaceID: r.workspace_id,
        senderPubkeyHex: r.sender_pubkey,
        recipientPubkeyHex: r.recipient_pubkey,
        kind: r.kind,
        encryptedPayload: decodePostgresByteaHex(r.encrypted_payload),
        crossPostJSON: r.cross_post?.jsonString,
        createdAtISO: r.created_at,
        readAtISO: r.read_at,
        doneAtISO: r.done_at,
        doneByPubkeyHex: r.done_by_pubkey,
        replyTo: r.reply_to
      )
    }
  }

  /// Mark message as read — PATCH `direct_messages?message_id=eq.<id>` with `{read_at: nowISO}`.
  /// RLS allows recipient (and sender per S4 policy widening) UPDATE.
  public func markRead(messageID: String, readAtISO: String) async throws {
    try await patchDirectMessage(
      messageID: messageID,
      body: ["read_at": readAtISO],
      label: "markRead"
    )
  }

  /// Mark task as done — PATCH with `{done_at: nowISO, done_by_pubkey: <hex>}`.
  public func markDone(messageID: String, doneAtISO: String, doneByPubkeyHex: String) async throws {
    try await patchDirectMessage(
      messageID: messageID,
      body: ["done_at": doneAtISO, "done_by_pubkey": doneByPubkeyHex],
      label: "markDone"
    )
  }

  private func patchDirectMessage(
    messageID: String,
    body: [String: Any],
    label: String
  ) async throws {
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.directMessagesPatch(baseURL: baseURL, messageID: messageID)
    var request = URLRequest(url: url)
    request.httpMethod = "PATCH"
    for (k, v) in SupabaseEndpoint.postgrestPatchHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await transport(
      request, label: label, retryable: true, refreshable: true)
    // PostgREST PATCH returns 204 No Content on success when Prefer: return=minimal.
    guard response.statusCode == 204 || response.statusCode == 200 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
  }

  /// Register APNs token — UPSERT `apns_tokens` via PostgREST.
  /// RLS allows self (pubkey = JWT pubkey). PK `(pubkey, device_id)` enables UPSERT
  /// via `Prefer: resolution=merge-duplicates`.
  public func registerAPNsToken(
    deviceID: String,
    apnsToken: String,
    environment: String
  ) async throws {
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.apnsTokensUpsert(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.postgrestUpsertHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    // I1 fix — fail fast if JWT lacks pubkey claim.
    guard let pubkeyClaim = session.pubkeyClaim, !pubkeyClaim.isEmpty else {
      throw SupabaseError.identityClaimMissing
    }
    let body: [String: String] = [
      "pubkey": pubkeyClaim,
      "device_id": deviceID,
      "apns_token": apnsToken,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    // environment intentionally not sent — server-side `apns_tokens` table has no
    // environment column (Track 5 contract §5.1). Local `apns_token_local` retains
    // env distinction for client-side debugging.
    _ = environment

    let (data, response) = try await transport(
      request, label: "registerAPNsToken", retryable: false, refreshable: true)
    guard response.statusCode == 201 || response.statusCode == 200 || response.statusCode == 204
    else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
  }

  /// Trigger APNs push via Edge Function — fire-and-forget after sender INSERTs.
  ///
  /// Track 5 / S8 / T5 — `kind` field added. Server uses it for two purposes:
  ///   1. `aps.category = "leaf.dm.<kind>"` binding to UNNotificationCategory
  ///      (Reply / Mark Done buttons rendered in banner per category config).
  ///   2. `aps.thread-id = "<workspace_id>:<kind>"` to give Notification
  ///      Center separate stacks per kind within the same workspace.
  ///   3. `notification_prefs` row lookup for recipient pubkey + this kind
  ///      → server-side skip with `skipped_by_prefs=true` if disabled.
  ///
  /// Caller (DirectMessageService.send) passes the current
  /// `DirectMessageKind.rawValue`; the cron `task_reminders` Edge Function
  /// internally hardcodes `kind: "task"` for the same reason.
  public func triggerAPNsPush(
    workspaceID: String,
    recipientPubkeyHex: String,
    messageID: String,
    titleText: String,
    kind: String,
    isReminder: Bool = false
  ) async throws -> SupabaseAPNsPushResult {
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.apnsPush(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.authenticatedHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let body: [String: Any] = [
      "workspace_id": workspaceID,
      "recipient_pubkey": recipientPubkeyHex,
      "message_id": messageID,
      "title": titleText,
      "kind": kind,
      "is_reminder": isReminder,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await transport(
      request, label: "triggerAPNsPush", retryable: false, refreshable: true)
    guard response.statusCode == 200 else {
      throw SupabaseError.fromStatus(response.statusCode, body: data)
    }
    struct Body: Decodable {
      let ok: Bool
      let devices_pushed: Int
      // T5: optional — present (true) only when notification_prefs
      // gates the push. Absent on normal success / partial failure.
      let skipped_by_prefs: Bool?
      // T5: optional — Edge Function omits `errors` on prefs skip.
      // Default to empty for graceful decode.
      let errors: [DeviceErr]?
      struct DeviceErr: Decodable {
        let device_id: String
        let status: Int
        let reason: String?
      }
    }
    let parsed: Body
    do {
      parsed = try JSONDecoder().decode(Body.self, from: data)
    } catch {
      throw SupabaseError.decoding(reason: "triggerAPNsPush: \(error)")
    }
    return SupabaseAPNsPushResult(
      devicesPushed: parsed.devices_pushed,
      errors: (parsed.errors ?? []).map {
        .init(deviceID: $0.device_id, status: $0.status, reason: $0.reason)
      },
      skippedByPrefs: parsed.skipped_by_prefs ?? false
    )
  }

  // MARK: - Internal helpers

  /// Shared transport — delegates to performHTTP (M-I task 5). retryable=true
  /// is allowed only for GET / idempotent PATCH callers (markRead/markDone
  /// SET <col>=<isoTimestamp> WHERE message_id=eq.X are safe to retry).
  private func transport(
    _ request: URLRequest,
    label: String,
    retryable: Bool = false,
    refreshable: Bool = false
  ) async throws -> (Data, HTTPURLResponse) {
    try await performHTTP(
      request, retryable: retryable, refreshable: refreshable, label: label)
  }

  private func decodePostgresByteaHex(_ s: String) -> Data {
    // PostgREST encodes bytea as `\x<hex>` (or `\\x<hex>` in JSON-escaped form).
    var hex = s
    if hex.hasPrefix("\\x") {
      hex = String(hex.dropFirst(2))
    }
    // Defensive: handle any leading backslash variations.
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
}

/// `direct_messages.cross_post` arrives as TEXT (legacy backend rows), as a
/// JSONB OBJECT (the migrated backend defaults new rows to `{}`), or null.
/// Decode all shapes to the JSON-string form the pipeline carries — mirrors
/// `RealtimeWebSocketDriver's tolerant `record["cross_post"]` handling. A
/// strict String decode here used to abort the ENTIRE inbound batch, which
/// permanently blocked message receive once any row carried a jsonb value.
struct TolerantCrossPostJSON: Decodable, Sendable {
  let jsonString: String?

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      jsonString = nil
    } else if let s = try? container.decode(String.self) {
      jsonString = s
    } else if let fragment = try? container.decode(JSONFragmentValue.self) {
      jsonString = fragment.rawJSONString
    } else {
      jsonString = nil
    }
  }
}

/// Minimal recursive JSON value — exists only so `TolerantCrossPostJSON` can
/// round-trip an arbitrary jsonb payload back into its string form.
indirect enum JSONFragmentValue: Codable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONFragmentValue])
  case object([String: JSONFragmentValue])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let b = try? c.decode(Bool.self) { self = .bool(b) }
    else if let n = try? c.decode(Double.self) { self = .number(n) }
    else if let s = try? c.decode(String.self) { self = .string(s) }
    else if let a = try? c.decode([JSONFragmentValue].self) { self = .array(a) }
    else { self = .object(try c.decode([String: JSONFragmentValue].self)) }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  var rawJSONString: String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
