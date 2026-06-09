//
//  SupabaseClientRealtimeAuthTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 — Phase D.1. Tests for `SupabaseClient.currentAccessToken()`
//  accessor used by RealtimeWebSocketDriver to seed phx_join payload.
//

import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientRealtimeAuthTests: XCTestCase {
  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon-key"

  override func tearDown() async throws {
    MockURLProtocol.handler = nil
  }

  private func fixedIdentity() -> @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey {
    let bytes = Data(repeating: 0x42, count: 32)
    return { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes) }
  }

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  func testCurrentAccessToken_WhenNotSignedIn_ReturnsNil() async {
    let client = SupabaseClient(
      baseURL: baseURL,
      anonKey: anonKey,
      urlSession: makeSession(),
      identity: fixedIdentity()
    )
    let token = await client.currentAccessToken()
    XCTAssertNil(token)
  }

  func testCurrentAccessToken_AfterSignIn_ReturnsAccessToken() async throws {
    // Stub signup + refresh — bootstrap completes with a known token.
    let signupBody = """
      {
        "access_token": "JWT.signup.aaa",
        "refresh_token": "refresh-xyz",
        "user": { "id": "00000000-0000-0000-0000-000000000111" },
        "expires_at": 9999999999
      }
      """.data(using: .utf8)!
    let refreshBody = """
      {
        "access_token": "JWT.refresh.bbb",
        "refresh_token": "refresh-xyz",
        "user": { "id": "00000000-0000-0000-0000-000000000111" },
        "expires_at": 9999999999
      }
      """.data(using: .utf8)!
    MockURLProtocol.handler = { request, _ in
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let url = request.url?.absoluteString ?? ""
      if url.contains("/auth/v1/signup") {
        return (resp, signupBody)
      } else if url.contains("/auth/v1/token") {
        return (resp, refreshBody)
      } else if url.contains("/functions/v1/register_pubkey") {
        return (resp, Data())
      } else {
        return (resp, Data())
      }
    }
    // Phase 1 (account-login) — anonymous bootstrap removed; seed a persisted
    // refresh-token so ensureAuthenticated() takes the persisted-refresh path
    // (hits /auth/v1/token → refreshBody) instead of the deleted anon signup.
    let seedDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-rtauth-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
    let seedStore = SupabaseSessionStore(at: seedDir)
    try? seedStore.write(
      PersistedSession(
        refreshToken: "refresh-xyz",
        userID: "00000000-0000-0000-0000-000000000111", savedAtMs: 1))
    let client = SupabaseClient(
      baseURL: baseURL,
      anonKey: anonKey,
      urlSession: makeSession(),
      identity: fixedIdentity(),
      sessionStore: seedStore
    )
    _ = try await client.ensureAuthenticated()
    let token = await client.currentAccessToken()
    // After bootstrap, the refresh has happened so JWT should be `JWT.refresh.bbb`.
    XCTAssertEqual(token, "JWT.refresh.bbb")
  }

  func testCurrentAccessToken_AfterSignOut_ReturnsNil() async throws {
    // Bootstrap then sign out.
    let stub = """
      {
        "access_token": "JWT.xx",
        "refresh_token": "refresh-xyz",
        "user": { "id": "00000000-0000-0000-0000-000000000111" },
        "expires_at": 9999999999
      }
      """.data(using: .utf8)!
    MockURLProtocol.handler = { request, _ in
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (resp, stub)
    }
    // Phase 1 (account-login) — anonymous bootstrap removed; seed a persisted
    // refresh-token so ensureAuthenticated() takes the persisted-refresh path
    // (hits /auth/v1/token → stub) instead of the deleted anon signup.
    let seedDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-rtauth-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
    let seedStore = SupabaseSessionStore(at: seedDir)
    try? seedStore.write(
      PersistedSession(
        refreshToken: "refresh-xyz",
        userID: "00000000-0000-0000-0000-000000000111", savedAtMs: 1))
    let client = SupabaseClient(
      baseURL: baseURL,
      anonKey: anonKey,
      urlSession: makeSession(),
      identity: fixedIdentity(),
      sessionStore: seedStore
    )
    _ = try await client.ensureAuthenticated()
    await client.signOut()
    let token = await client.currentAccessToken()
    XCTAssertNil(token)
  }
}
