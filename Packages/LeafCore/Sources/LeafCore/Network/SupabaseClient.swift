//
//  SupabaseClient.swift
//  LeafCore
//
//  Track 5 / S3 — Leaf's first network primitive talking to Supabase. Handles
//  anonymous auth bootstrap, register_pubkey, invite_resolve, and JWT-bearing
//  PostgREST INSERTs. Actor for concurrency safety. URLSession injection for tests.
//
//  Construction is sync; first network call lazily bootstraps auth via
//  ensureAuthenticated() (Task 2-3). Skeleton (this task) just lays the
//  property surface — no HTTP wire yet.
//

import CryptoKit
import Foundation

public actor SupabaseClient {
  // Track 5 / S7 H.1 — `baseURL` and `anonKey` are immutable post-init and
  // safely readable from nonisolated contexts (e.g., Realtime URL composition
  // at LeafApp.init time). Marking `nonisolated let` makes them callable
  // without an `await` actor hop.
  public nonisolated let baseURL: URL
  public nonisolated let anonKey: String
  internal let urlSession: URLSession
  private let identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey
  internal let now: @Sendable () -> Date
  private let sessionStore: SupabaseSessionStore?

  private var state: BootstrapState = .notAuthenticated

  /// Wall-clock timestamp of the most recent successful token refresh (or
  /// initial bootstrap completion). Used by `ensureFreshSession()` to guard
  /// against NTP-skew drift: even if the JWT `exp` claim is far away, force
  /// a refresh after ~55min so a long-running session never silently rides
  /// past server-side expiry on a clock-skewed device.
  private var lastRefreshAt: Date?

  /// Coalescing slot for concurrent `ensureFreshSession()` callers. The
  /// first caller installs a Task here; subsequent callers `await` the same
  /// Task instead of firing a duplicate `/auth/v1/token` request.
  private var inflightFreshSessionTask: Task<SupabaseAuthSession, Error>?

  /// Phase M-I — transient-failure retry policy applied to GET/PATCH (idempotent)
  /// callers of `performHTTP`. POST callers pass `retryable: false` and bypass
  /// the retry loop entirely (waiting on M-II server-side Idempotency-Key dedup).
  internal let retryPolicy: RetryPolicy

  /// Phase M-I — clock injection for retry-loop sleeps. Production default uses
  /// cancellation-aware `Task.sleep(for:)`; tests inject a no-op or a throwing
  /// variant to verify cancellation propagation without wall-clock waits.
  internal let sleep: @Sendable (Duration) async throws -> Void

  public init(
    baseURL: URL,
    anonKey: String,
    urlSession: URLSession = .shared,
    identity: @escaping @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey,
    now: @escaping @Sendable () -> Date = { Date() },
    sessionStore: SupabaseSessionStore? = nil,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.baseURL = baseURL
    self.anonKey = anonKey
    self.urlSession = urlSession
    self.identity = identity
    self.now = now
    self.sessionStore = sessionStore
    self.retryPolicy = retryPolicy
    self.sleep = sleep
  }

  public func currentSession() -> SupabaseAuthSession? {
    if case .authenticated(let s) = state { return s }
    return nil
  }

  /// Phase 1 — full sign-out: drop in-memory auth state, cancel any pending
  /// refresh, and delete the persisted refresh_token so the next cold start
  /// (UI gate + agent) sees no session and shows LoginView / idles. Store
  /// clear is best-effort: a clear failure must not strand the user in a
  /// signed-in-looking state, so the in-memory drop always happens.
  public func signOut() {
    state = .notAuthenticated
    lastRefreshAt = nil
    inflightFreshSessionTask?.cancel()
    inflightFreshSessionTask = nil
    if let store = sessionStore {
      try? store.clear()
    }
  }

  // MARK: - Public — ensureAuthenticated

  /// Phase 1 — NO anonymous fallback. Resolution order:
  ///   1. valid in-memory session (expiresAt > now) → return;
  ///   2. else persisted refresh_token → tokenRefresh → install + return;
  ///   3. else throw `.unauthorized` (gate shows LoginView; agent exit(0)).
  /// Concurrent callers share the in-flight refresh via `.bootstrapping`.
  public func ensureAuthenticated() async throws -> SupabaseAuthSession {
    if case .authenticated(let s) = state, s.expiresAt > now() { return s }
    if case .bootstrapping(let task) = state { return try await task.value }

    let task = Task { try await self.resolvePersistedOrThrow() }
    state = .bootstrapping(task)
    do {
      let session = try await task.value
      state = .authenticated(session)
      lastRefreshAt = now()
      return session
    } catch {
      state = .notAuthenticated
      throw error
    }
  }

  /// Step 2/3 of ensureAuthenticated: try persisted refresh, else throw.
  private func resolvePersistedOrThrow() async throws -> SupabaseAuthSession {
    if let store = sessionStore, let persisted = readPersistedBestEffort(store: store) {
      let refreshed = try await performTokenRefresh(refreshToken: persisted.refreshToken)
      persistSessionBestEffort(store: store, session: refreshed)
      return refreshed
    }
    throw SupabaseError.unauthorized
  }

  /// Post-login device registration sequence (spec §4). Requires that a
  /// login (signInWithPassword / exchangeOAuthCode) has already installed an
  /// authenticated session, OR a persisted refresh exists. Then:
  ///   1. registerPubkey(accessToken)  — row in pubkey_registry;
  ///   2. tokenRefresh                 — new JWT with the pubkey claim (JWT hook);
  ///   3. require pubkey claim present, else throw `.identityClaimMissing`.
  /// Idempotent on the registerPubkey 409 path is the caller's concern
  /// (TOFU collision surfaces as `.pubkeyAlreadyRegistered`).
  public func ensureAuthenticatedAndPubkeyRegistered() async throws -> SupabaseAuthSession {
    let current = try await ensureAuthenticated()
    if let claim = current.pubkeyClaim, !claim.isEmpty { return current }
    try await performRegisterPubkey(accessToken: current.accessToken)
    let refreshed = try await performTokenRefresh(refreshToken: current.refreshToken)
    state = .authenticated(refreshed)
    lastRefreshAt = now()
    if let store = sessionStore {
      persistSessionBestEffort(store: store, session: refreshed)
    }
    guard let claim = refreshed.pubkeyClaim, !claim.isEmpty else {
      throw SupabaseError.identityClaimMissing
    }
    return refreshed
  }

  // MARK: - ensureFreshSession (P1 hot-fix — JWT refresh for Realtime)

  /// Refresh the access_token if it's near expiry OR the NTP-skew margin
  /// has been exceeded; otherwise return the cached session unchanged.
  ///
  /// Refresh policy (matches P1 hot-fix spec §3.3):
  /// * exp − now < 60s — explicit near-expiry trigger.
  /// * lastRefreshAt + 55min < now — NTP-skew defense; covers devices
  ///   whose clock drifts (asleep overnight, manual time changes) where
  ///   the JWT exp claim looks far away but the server already considers
  ///   the token expired.
  ///
  /// Concurrent callers coalesce on `inflightFreshSessionTask` — at most
  /// one `/auth/v1/token` POST is in flight at a time. Errors are
  /// surfaced to all coalesced callers identically.
  ///
  /// Throws `SupabaseError.unauthorized` if called before any successful
  /// bootstrap (no cached session to refresh from). Caller is expected to
  /// have driven `ensureAuthenticated()` at app startup.
  ///
  /// - Parameter force: M-III addition. When `true`, bypasses the
  ///   `shouldRefresh` predicate and forces a fresh `/auth/v1/token` POST.
  ///   Used by the 401-recovery path in `performHTTP`: a 401 from the
  ///   server means the cached JWT is rejected regardless of what
  ///   `shouldRefresh`'s local heuristics think (server-side rotation /
  ///   revocation / out-of-band invalidation). Still coalesces concurrent
  ///   callers via `inflightFreshSessionTask`.
  public func ensureFreshSession(force: Bool = false) async throws -> SupabaseAuthSession {
    // Coalesce: if a refresh is already in flight, await it.
    if let task = inflightFreshSessionTask {
      return try await task.value
    }

    // Cold-launch race (P1 code-review I1): a Realtime reconnect can fire
    // ensureFreshSession concurrent with the very first
    // ensureAuthenticated() bootstrap. Mirror ensureAuthenticated's
    // pattern — await the in-flight Task instead of throwing
    // .unauthorized. After the bootstrap returns, re-check shouldRefresh
    // against the freshly-bootstrapped session. If refresh isn't needed
    // (typical — bootstrap finishes with a token refresh, lastRefreshAt
    // is freshly stamped), return it directly. Otherwise fall through to
    // the refresh path which will read the now-`.authenticated` state.
    if case .bootstrapping(let task) = state {
      let bootstrapped = try await task.value
      if !force, !shouldRefresh(session: bootstrapped) {
        return bootstrapped
      }
    }

    // Need an existing session to refresh from.
    //
    // M-III review note: under `force=true` with concurrent
    // `ensureAuthenticated` bootstrap in flight, both awaiters resume FIFO
    // on the actor. The bootstrap's creator (ensureAuthenticated:80-86)
    // writes `state = .authenticated(session)` before this `force=true`
    // continuation reaches the guard, so the guard succeeds. A concurrent
    // `signOut()` interleaved between those two resumptions could land us
    // in `.notAuthenticated` and throw `.unauthorized` — acceptable: the
    // user explicitly signed out, so a forced refresh is meaningless.
    guard case .authenticated(let current) = state else {
      throw SupabaseError.unauthorized
    }

    // Should-we-refresh decision (cheap, runs every caller). Bypassed when
    // `force=true` — caller (typically the 401-recovery path) has out-of-
    // band evidence that the cached JWT is no longer accepted by the server.
    if !force, !shouldRefresh(session: current) {
      return current
    }

    // Install an inflight Task; concurrent callers share its value.
    let refreshToken = current.refreshToken
    let task = Task { [weak self] in
      guard let self else { throw SupabaseError.unauthorized }
      return try await self.performFreshSessionRefresh(refreshToken: refreshToken)
    }
    inflightFreshSessionTask = task
    do {
      let refreshed = try await task.value
      // Successful completion: persist if a sessionStore is wired so
      // app cold-start picks up the rotated refresh_token.
      if let store = sessionStore {
        persistSessionBestEffort(store: store, session: refreshed)
      }
      inflightFreshSessionTask = nil
      return refreshed
    } catch {
      inflightFreshSessionTask = nil
      throw error
    }
  }

  /// Pure decision predicate. Extracted so it stays trivially testable and
  /// the two trigger conditions are documented in one place.
  private func shouldRefresh(session: SupabaseAuthSession) -> Bool {
    let nowDate = now()
    // Trigger 1: near expiry (< 60s remaining).
    let secondsToExpiry = session.expiresAt.timeIntervalSince(nowDate)
    if secondsToExpiry < 60 { return true }
    // Trigger 2: NTP-skew margin exceeded (lastRefreshAt + 55min < now).
    if let last = lastRefreshAt {
      if nowDate.timeIntervalSince(last) > (55 * 60) { return true }
    }
    return false
  }

  /// Refresh path that ALSO updates the actor's state + lastRefreshAt.
  /// Separated from `performTokenRefresh` so the bootstrap flow (which
  /// owns its own state-transition logic) stays untouched.
  private func performFreshSessionRefresh(refreshToken: String) async throws -> SupabaseAuthSession
  {
    let refreshed = try await performTokenRefresh(refreshToken: refreshToken)
    state = .authenticated(refreshed)
    lastRefreshAt = now()
    return refreshed
  }

  #if DEBUG
    /// Test-only inspector for the lastRefreshAt timestamp.
    public func lastRefreshAtForTesting() -> Date? { lastRefreshAt }
  #endif

  private func readPersistedBestEffort(store: SupabaseSessionStore) -> PersistedSession? {
    do {
      return try store.read()
    } catch {
      // Log + proceed as if no persisted session.
      return nil
    }
  }

  private func persistSessionBestEffort(store: SupabaseSessionStore, session: SupabaseAuthSession) {
    let persisted = PersistedSession(
      refreshToken: session.refreshToken,
      userID: session.userID.uuidString.lowercased(),
      savedAtMs: Int64(now().timeIntervalSince1970 * 1000)
    )
    try? store.write(persisted)
  }

  private func decodeAuthResponse(request: URLRequest, label: String) async throws
    -> SupabaseAuthSession
  {
    let (data, http) = try await performHTTP(request, retryable: false, label: label)
    guard http.statusCode == 200 else {
      throw SupabaseError.fromStatus(http.statusCode, body: data)
    }
    struct Body: Decodable {
      let access_token: String
      let refresh_token: String
      let user: User
      let expires_at: Int64?
      struct User: Decodable { let id: String }
    }
    let body: Body
    do {
      body = try JSONDecoder().decode(Body.self, from: data)
    } catch {
      throw SupabaseError.decoding(reason: "\(label): \(error)")
    }
    guard let userID = UUID(uuidString: body.user.id) else {
      throw SupabaseError.decoding(reason: "\(label): bad user id")
    }
    let expiresAt =
      body.expires_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
      ?? now().addingTimeInterval(60 * 60)
    return SupabaseAuthSession(
      accessToken: body.access_token,
      refreshToken: body.refresh_token,
      userID: userID,
      expiresAt: expiresAt,
      pubkeyClaim: nil
    )
  }

  // MARK: - Internal HTTP — tokenRefresh

  private func performTokenRefresh(refreshToken: String) async throws -> SupabaseAuthSession {
    let url = SupabaseEndpoint.tokenRefresh(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.anonHeaders(anonKey: anonKey) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let body: [String: String] = ["refresh_token": refreshToken]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let session = try await decodeAuthResponse(request: request, label: "tokenRefresh")
    // Populate pubkeyClaim from the new JWT's claims (best-effort decode).
    return session.populatingPubkeyClaim()
  }

  // MARK: - Internal HTTP — registerPubkey

  private func performRegisterPubkey(accessToken: String) async throws {
    let priv = try identity()
    let pubkeyHex = priv.publicKey.rawRepresentation
      .map { String(format: "%02x", $0) }.joined()

    let url = SupabaseEndpoint.registerPubkey(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.authenticatedHeaders(anonKey: anonKey, accessToken: accessToken)
    {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let body: [String: String] = ["pubkey": pubkeyHex]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, http) = try await performHTTP(request, retryable: false, label: "registerPubkey")
    if http.statusCode == 200 { return }
    throw SupabaseError.fromRegisterPubkey(status: http.statusCode, body: data)
  }

  enum BootstrapState {
    case notAuthenticated
    case bootstrapping(Task<SupabaseAuthSession, Error>)
    case authenticated(SupabaseAuthSession)
  }
}

// MARK: - IssuedInvite (Track 5 / S3 — postInvite response shape)

public struct IssuedInvite: Sendable, Equatable {
  public let tokenUUID: UUID
  public let tokenBase64URL: String
  public let workspaceID: String
  public let expiresAtISO8601: String

  public init(
    tokenUUID: UUID, tokenBase64URL: String, workspaceID: String, expiresAtISO8601: String
  ) {
    self.tokenUUID = tokenUUID
    self.tokenBase64URL = tokenBase64URL
    self.workspaceID = workspaceID
    self.expiresAtISO8601 = expiresAtISO8601
  }
}

// MARK: - UUID ↔ base64url helpers

extension UUID {
  /// 22-char base64url-no-padding encoding of the 16-byte raw UUID.
  public var base64URLString: String {
    let bytes = withUnsafeBytes(of: self.uuid) { Data($0) }
    return bytes.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public init?(base64URLString: String) {
    var s =
      base64URLString
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let pad = (4 - s.count % 4) % 4
    s += String(repeating: "=", count: pad)
    guard let data = Data(base64Encoded: s), data.count == 16 else { return nil }
    let uuid: uuid_t = data.withUnsafeBytes { rawPtr in
      rawPtr.load(as: uuid_t.self)
    }
    self.init(uuid: uuid)
  }
}

// MARK: - SupabaseClient.postInvite (admin path — Track 5 / S3)

extension SupabaseClient {
  /// Admin path — POST invite row to Supabase `invites` table via PostgREST.
  /// Caller (InviteService) provides crypto blob bytes; we hex-encode for bytea wire.
  /// Returns: IssuedInvite with both UUID and base64url representations of the server-issued token.
  public func postInvite(
    workspaceID: String,
    adminPubkeyHex: String,
    encryptedTeamkey: Data,
    expiresAt: Date,
    requireOTP: Bool,
    otpHashBase64: String?
  ) async throws -> IssuedInvite {
    let session = try await ensureAuthenticated()

    let url = SupabaseEndpoint.postInvite(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.postgrestInsertHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let teamkeyHex = "\\x" + encryptedTeamkey.map { String(format: "%02x", $0) }.joined()
    let iso = Self.iso8601(from: expiresAt)
    var body: [String: Any] = [
      "workspace_id": workspaceID,
      "admin_pubkey": adminPubkeyHex,
      "encrypted_teamkey": teamkeyHex,
      "expires_at": iso,
      "require_otp": requireOTP,
    ]
    if let otpHashBase64, let bytes = Data(base64Encoded: otpHashBase64) {
      // PostgREST bytea: decode base64 → hex with \x prefix
      body["otp_hash"] = "\\x" + bytes.map { String(format: "%02x", $0) }.joined()
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, http) = try await performHTTP(
      request, retryable: false, refreshable: true, label: "postInvite")
    guard http.statusCode == 201 else {
      throw SupabaseError.fromStatus(http.statusCode, body: data)
    }

    struct Row: Decodable {
      let token: String
      let workspace_id: String
      let expires_at: String
    }
    let rows: [Row]
    do {
      rows = try JSONDecoder().decode([Row].self, from: data)
    } catch {
      throw SupabaseError.decoding(reason: "postInvite: \(error)")
    }
    guard let first = rows.first,
      let uuid = UUID(uuidString: first.token)
    else {
      throw SupabaseError.decoding(reason: "postInvite: empty rows or bad uuid")
    }
    return IssuedInvite(
      tokenUUID: uuid,
      tokenBase64URL: uuid.base64URLString,
      workspaceID: first.workspace_id,
      expiresAtISO8601: first.expires_at
    )
  }

  private static func iso8601(from date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }
}

// MARK: - ResolvedInvite + InviteProbeStatus value types (Track 5 / S3)

public struct ResolvedInvite: Sendable, Equatable {
  public let encryptedTeamkey: Data  // decoded from base64url
  public let adminPubkey: String  // 64-hex
  public let workspaceID: String  // uuid
  public let workspaceName: String
  public let requireOTP: Bool
  public let expiresAtISO8601: String
}

public enum InviteProbeStatus: Sendable, Equatable {
  case pending
  case claimed(by: String, at: String)
  case expired
  case notFound
}

// MARK: - resolveInvite + probeInvite (invitee path; no JWT)

extension SupabaseClient {
  public func resolveInvite(token: String, inviteePubkeyHex: String) async throws -> ResolvedInvite
  {
    let url = SupabaseEndpoint.inviteResolve(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // Anon: no Authorization header (token is the auth at Edge Function layer), but
    // Supabase production gateway (Kong) requires `apikey` header on every request.
    // Local `supabase functions serve --no-verify-jwt` was permissive; production is not.
    for (k, v) in SupabaseEndpoint.anonHeaders(anonKey: anonKey) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let body: [String: Any] = [
      "token": token,
      "invitee_pubkey": inviteePubkeyHex,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, http) = try await performHTTP(request, retryable: false, label: "resolveInvite")
    guard http.statusCode == 200 else {
      throw SupabaseError.fromInviteResolve(status: http.statusCode, body: data)
    }
    struct Body: Decodable {
      let encrypted_teamkey: String
      let admin_pubkey: String
      let workspace_id: String
      let workspace_name: String
      let require_otp: Bool
      let expires_at: String
    }
    let parsed: Body
    do { parsed = try JSONDecoder().decode(Body.self, from: data) } catch {
      throw SupabaseError.decoding(reason: "resolveInvite: \(error)")
    }
    guard let blobBytes = Self.base64URLDecode(parsed.encrypted_teamkey) else {
      throw SupabaseError.decoding(reason: "resolveInvite: bad encrypted_teamkey")
    }
    return ResolvedInvite(
      encryptedTeamkey: blobBytes,
      adminPubkey: parsed.admin_pubkey,
      workspaceID: parsed.workspace_id,
      workspaceName: parsed.workspace_name,
      requireOTP: parsed.require_otp,
      expiresAtISO8601: parsed.expires_at
    )
  }

  public func probeInvite(token: String) async throws -> InviteProbeStatus {
    let url = SupabaseEndpoint.inviteResolve(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // Anon: apikey required by Supabase production gateway (same shape as resolveInvite above).
    for (k, v) in SupabaseEndpoint.anonHeaders(anonKey: anonKey) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "probe": true])

    let (data, http) = try await performHTTP(request, retryable: false, label: "probeInvite")
    guard http.statusCode == 200 else {
      throw SupabaseError.fromStatus(http.statusCode, body: data)
    }
    struct Body: Decodable {
      let status: String
      let claimed_at: String?
      let claimed_by_pubkey: String?
      let expires_at: String?
    }
    let body: Body
    do { body = try JSONDecoder().decode(Body.self, from: data) } catch {
      throw SupabaseError.decoding(reason: "probeInvite: \(error)")
    }
    switch body.status {
    case "pending": return .pending
    case "claimed":
      return .claimed(by: body.claimed_by_pubkey ?? "", at: body.claimed_at ?? "")
    case "expired": return .expired
    case "not_found": return .notFound
    default: throw SupabaseError.decoding(reason: "probeInvite: unknown status \(body.status)")
    }
  }

  static func base64URLDecode(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let pad = (4 - t.count % 4) % 4
    t += String(repeating: "=", count: pad)
    return Data(base64Encoded: t)
  }
}

// MARK: - insertWorkspaceMember (PostgREST INSERT via JWT)

extension SupabaseClient {
  public func insertWorkspaceMember(
    workspaceID: String,
    pubkeyHex: String,
    displayName: String
  ) async throws {
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.insertWorkspaceMember(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.postgrestInsertHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let body: [String: Any] = [
      "workspace_id": workspaceID,
      "pubkey": pubkeyHex,
      "display_name": displayName,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, http) = try await performHTTP(
      request, retryable: false, refreshable: true, label: "insertWorkspaceMember")
    guard http.statusCode == 201 else {
      throw SupabaseError.fromStatus(http.statusCode, body: data)
    }
  }

  /// Idempotent variant of `insertWorkspaceMember` — POSTs the row and treats a
  /// 409 (PK conflict on `(workspace_id, pubkey)`, i.e. the member already
  /// exists) as success. Used by the workspace-CREATE path to materialise the
  /// creator's OWN membership row: `direct_messages` / handoff RLS gates the
  /// sender on `is_workspace_member(workspace_id, jwt.pubkey)`, but
  /// `insertWorkspace` only writes the `workspaces` row — so without this the
  /// admin 403s on their first DM/handoff in a freshly-created workspace. RLS
  /// permits the self-insert (JWT pubkey == the row's pubkey). 409-tolerant so
  /// it's safe on a re-create or when a prior sync / server backfill already
  /// added the row.
  public func ensureWorkspaceMember(
    workspaceID: String,
    pubkeyHex: String,
    displayName: String
  ) async throws {
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.insertWorkspaceMember(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.postgrestInsertHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let body: [String: Any] = [
      "workspace_id": workspaceID,
      "pubkey": pubkeyHex,
      "display_name": displayName,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, http) = try await performHTTP(
      request, retryable: false, refreshable: true, label: "ensureWorkspaceMember")
    // 201 Created, or 409 conflict (already a member) — both are success for an
    // idempotent ensure. Anything else is a real error.
    guard http.statusCode == 201 || http.statusCode == 409 else {
      throw SupabaseError.fromStatus(http.statusCode, body: data)
    }
  }

  /// Full workspace roster read-back. RLS `workspace_members_peer_read` permits
  /// any member to SELECT the whole roster; `WorkspaceRosterSyncService`
  /// reconciles these into the local `team_members` so invitees see each other.
  public func fetchWorkspaceMembers(workspaceID: String) async throws -> [WorkspaceMemberRow] {
    let session = try await ensureAuthenticated()
    let url = SupabaseEndpoint.listWorkspaceMembers(baseURL: baseURL, workspaceID: workspaceID)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    for (k, v) in SupabaseEndpoint.authenticatedHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let (data, http) = try await performHTTP(
      request, retryable: true, refreshable: true, label: "fetchWorkspaceMembers")
    guard http.statusCode == 200 else {
      throw SupabaseError.fromStatus(http.statusCode, body: data)
    }
    struct Row: Decodable {
      let pubkey: String
      let display_name: String
    }
    let rows = try JSONDecoder().decode([Row].self, from: data)
    return rows.map { WorkspaceMemberRow(pubkeyHex: $0.pubkey, displayName: $0.display_name) }
  }
}

/// One row of the server `workspace_members` roster (pubkey + display name).
public struct WorkspaceMemberRow: Sendable, Equatable {
  public let pubkeyHex: String
  public let displayName: String

  public init(pubkeyHex: String, displayName: String) {
    self.pubkeyHex = pubkeyHex
    self.displayName = displayName
  }
}

// MARK: - SupabaseAuthSession JWT claim extraction

extension SupabaseAuthSession {
  /// Returns a copy with pubkeyClaim populated from the access_token JWT (if present).
  /// Failure (malformed JWT, no pubkey claim) returns self unchanged — caller can detect via nil.
  func populatingPubkeyClaim() -> SupabaseAuthSession {
    guard let claim = Self.extractPubkeyClaim(fromJWT: self.accessToken) else { return self }
    return SupabaseAuthSession(
      accessToken: self.accessToken,
      refreshToken: self.refreshToken,
      userID: self.userID,
      expiresAt: self.expiresAt,
      pubkeyClaim: claim
    )
  }

  /// Decode the JWT payload without verifying the signature. The JWT
  /// itself was issued by Supabase (HS256 signed with Supabase's secret)
  /// and is validated server-side by PostgREST / Edge Functions on every
  /// request — that is where signature verification happens. The local
  /// extraction here is a convenience to read the `pubkey` claim out of
  /// the token we already trust (we received it as the auth response).
  /// Tampering would invalidate the JWT on the next server call.
  static func extractPubkeyClaim(fromJWT jwt: String) -> String? {
    let parts = jwt.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var middle = String(parts[1])
    middle = middle.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let pad = (4 - middle.count % 4) % 4
    middle += String(repeating: "=", count: pad)
    guard let data = Data(base64Encoded: middle),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return json["pubkey"] as? String
  }
}

// MARK: - Native login — email/password + OAuth code exchange (Phase 1)

extension SupabaseClient {
  /// Native email+password login. POST /auth/v1/token?grant_type=password.
  /// `captchaToken` is OPTIONAL: the shared project's global CAPTCHA protection
  /// is OFF, so the native app does NOT send a captcha token (the macOS app
  /// renders no Turnstile widget). When `captchaToken` is empty (the default),
  /// the `gotrue_meta_security` key is omitted from the body entirely; when a
  /// non-empty token IS supplied (e.g. a future captcha-on configuration), it
  /// is carried in `gotrue_meta_security.captcha_token`. Updates the actor's
  /// session state + lastRefreshAt and persists the refresh_token if a store is
  /// wired, so a subsequent app cold-start reuses it (no second prompt).
  /// Returns the session (pubkey claim NOT yet present — caller drives
  /// registerPubkey via `ensureAuthenticatedAndPubkeyRegistered`).
  public func signInWithPassword(
    email: String, password: String, captchaToken: String = ""
  ) async throws -> SupabaseAuthSession {
    let url = SupabaseEndpoint.signInWithPassword(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.anonHeaders(anonKey: anonKey) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    var body: [String: Any] = [
      "email": email,
      "password": password,
    ]
    if !captchaToken.isEmpty {
      body["gotrue_meta_security"] = ["captcha_token": captchaToken]
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let session = try await decodeAuthResponse(request: request, label: "signInWithPassword")
    installAuthenticatedSession(session)
    return session
  }

  /// Exchange an OAuth authorization code (delivered to leaf://auth/callback
  /// by ASWebAuthenticationSession) for a session. POST
  /// /auth/v1/token?grant_type=pkce with `auth_code` + `code_verifier`.
  /// OAuth (Google/GitHub) is exempt from CAPTCHA (spec §5.C) — no captcha
  /// token in the body. Updates state + persists like signInWithPassword.
  public func exchangeOAuthCode(
    code: String, codeVerifier: String, redirectURI: String
  ) async throws -> SupabaseAuthSession {
    let url = SupabaseEndpoint.oauthToken(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (k, v) in SupabaseEndpoint.anonHeaders(anonKey: anonKey) {
      request.setValue(v, forHTTPHeaderField: k)
    }
    let body: [String: Any] = [
      "auth_code": code,
      "code_verifier": codeVerifier,
      "redirect_uri": redirectURI,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let session = try await decodeAuthResponse(request: request, label: "exchangeOAuthCode")
    installAuthenticatedSession(session)
    return session
  }

  /// Shared post-login bookkeeping: set `.authenticated`, stamp lastRefreshAt,
  /// best-effort persist. Private to this extension; mirrors the bootstrap's
  /// tail in `ensureAuthenticated`.
  private func installAuthenticatedSession(_ session: SupabaseAuthSession) {
    state = .authenticated(session)
    lastRefreshAt = now()
    if let store = sessionStore {
      persistSessionBestEffort(store: store, session: session)
    }
  }
}
