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

    // MARK: - Test-only DEBUG surface (Task 2 transient — Task 3 replaces with ensureAuthenticated)

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
