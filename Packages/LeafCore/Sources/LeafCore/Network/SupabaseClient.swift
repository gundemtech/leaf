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

    enum BootstrapState {
        case notAuthenticated
        case bootstrapping(Task<SupabaseAuthSession, Error>)
        case authenticated(SupabaseAuthSession)
    }
}
