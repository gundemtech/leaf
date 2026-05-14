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
    public let baseURL: URL
    public let anonKey: String
    private let urlSession: URLSession
    private let identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey
    private let now: @Sendable () -> Date

    private var state: BootstrapState = .notAuthenticated

    public init(baseURL: URL,
                anonKey: String,
                urlSession: URLSession = .shared,
                identity: @escaping @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.urlSession = urlSession
        self.identity = identity
        self.now = now
    }

    public func currentSession() -> SupabaseAuthSession? {
        if case .authenticated(let s) = state { return s }
        return nil
    }

    public func signOut() {
        state = .notAuthenticated
    }

    // MARK: - Public — ensureAuthenticated

    /// Idempotent. Returns cached session if still valid; otherwise performs
    /// 3-step bootstrap: signInAnonymously → registerPubkey → token refresh.
    /// Concurrent callers share the in-flight bootstrap via .bootstrapping(task).
    public func ensureAuthenticated() async throws -> SupabaseAuthSession {
        if case .authenticated(let s) = state, s.expiresAt > now() { return s }
        if case .bootstrapping(let task) = state { return try await task.value }

        let task = Task { try await self.performBootstrap() }
        state = .bootstrapping(task)
        do {
            let session = try await task.value
            state = .authenticated(session)
            return session
        } catch {
            state = .notAuthenticated
            throw error
        }
    }

    private func performBootstrap() async throws -> SupabaseAuthSession {
        let initial = try await performSignInAnonymously()
        try await performRegisterPubkey(accessToken: initial.accessToken)
        let refreshed = try await performTokenRefresh(refreshToken: initial.refreshToken)
        return refreshed
    }

    // MARK: - Internal HTTP — signInAnonymously

    /// Internal: signs in anonymously via Supabase Auth. Idempotent failure mode —
    /// network error / 4xx / malformed body throw SupabaseError; state stays
    /// .notAuthenticated for caller to retry.
    private func performSignInAnonymously() async throws -> SupabaseAuthSession {
        let url = SupabaseEndpoint.signupAnonymous(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in SupabaseEndpoint.anonHeaders(anonKey: anonKey) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = "{}".data(using: .utf8)
        return try await decodeAuthResponse(request: request, label: "signupAnonymous")
    }

    private func decodeAuthResponse(request: URLRequest, label: String) async throws -> SupabaseAuthSession {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SupabaseError.transport(reason: "\(label): \(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.transport(reason: "\(label): non-http")
        }
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
        let expiresAt = body.expires_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
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
        for (k, v) in SupabaseEndpoint.authenticatedHeaders(anonKey: anonKey, accessToken: accessToken) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let body: [String: String] = ["pubkey": pubkeyHex]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SupabaseError.transport(reason: "registerPubkey: \(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.transport(reason: "registerPubkey: non-http")
        }
        if http.statusCode == 200 { return }
        throw SupabaseError.fromRegisterPubkey(status: http.statusCode, body: data)
    }

    // MARK: - Test-only DEBUG surface (Task 2 transient — Task 3 superseded by ensureAuthenticated)

    #if DEBUG
    public func performSignInAnonymouslyForTesting() async throws -> SupabaseAuthSession {
        try await performSignInAnonymously()
    }
    #endif

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

    public init(tokenUUID: UUID, tokenBase64URL: String, workspaceID: String, expiresAtISO8601: String) {
        self.tokenUUID = tokenUUID
        self.tokenBase64URL = tokenBase64URL
        self.workspaceID = workspaceID
        self.expiresAtISO8601 = expiresAtISO8601
    }
}

// MARK: - UUID ↔ base64url helpers

public extension UUID {
    /// 22-char base64url-no-padding encoding of the 16-byte raw UUID.
    var base64URLString: String {
        let bytes = withUnsafeBytes(of: self.uuid) { Data($0) }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        var s = base64URLString
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
    public func postInvite(workspaceID: String,
                           adminPubkeyHex: String,
                           encryptedTeamkey: Data,
                           expiresAt: Date,
                           requireOTP: Bool,
                           otpHashBase64: String?) async throws -> IssuedInvite {
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

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SupabaseError.transport(reason: "postInvite: \(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.transport(reason: "postInvite: non-http")
        }
        guard http.statusCode == 201 else {
            throw SupabaseError.fromStatus(http.statusCode, body: data)
        }

        struct Row: Decodable { let token: String; let workspace_id: String; let expires_at: String }
        let rows: [Row]
        do {
            rows = try JSONDecoder().decode([Row].self, from: data)
        } catch {
            throw SupabaseError.decoding(reason: "postInvite: \(error)")
        }
        guard let first = rows.first,
              let uuid = UUID(uuidString: first.token) else {
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

    static func extractPubkeyClaim(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var middle = String(parts[1])
        middle = middle.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - middle.count % 4) % 4
        middle += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: middle),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["pubkey"] as? String
    }
}
