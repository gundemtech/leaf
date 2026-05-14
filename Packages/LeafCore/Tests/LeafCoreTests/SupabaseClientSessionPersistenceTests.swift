// Phase Track-5 S4 — SupabaseClient sessionStore load-on-bootstrap coverage.
// Closes S3 carry-over I3 (refresh_token persistence).

import XCTest
import CryptoKit
@testable import LeafCore

final class SupabaseClientSessionPersistenceTests: XCTestCase {
    private let baseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "test-anon-key"
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-supabase-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func fixedIdentity() -> @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey {
        let bytes = Data(repeating: 0x42, count: 32)
        return { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes) }
    }

    private func makeJWT(pubkey: String, userID: String) -> String {
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"pubkey":"\#(pubkey)","sub":"\#(userID)"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).fake-sig"
    }

    // MARK: - First launch — no persisted session → fresh signup + persist

    func testFirstLaunch_NoPersistedSession_FreshSignupAndPersist() async throws {
        let pubkey = String(repeating: "42", count: 32)
        let userID = "00000000-0000-0000-0000-000000000aaa"
        let jwt = makeJWT(pubkey: pubkey, userID: userID)

        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "tok-1", "refresh_token": "fresh-rt-1",
                          "user": { "id": "\(userID)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "\(jwt)", "refresh_token": "refreshed-rt-1",
                          "user": { "id": "\(userID)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            default:
                XCTFail("unexpected url \(path)")
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let store = SupabaseSessionStore(at: tempDir)
        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity(),
            sessionStore: store
        )
        let session = try await client.ensureAuthenticated()
        XCTAssertEqual(session.refreshToken, "refreshed-rt-1")

        // Persisted session captured.
        let persisted = try store.read()
        XCTAssertEqual(persisted?.refreshToken, "refreshed-rt-1")
        XCTAssertEqual(persisted?.userID, userID)
    }

    // MARK: - Second launch — persisted session → token refresh shortcut, no signup

    func testSecondLaunch_PersistedSession_UsesTokenRefresh_NoSignup() async throws {
        let pubkey = String(repeating: "42", count: 32)
        let userID = "00000000-0000-0000-0000-000000000bbb"
        let jwt = makeJWT(pubkey: pubkey, userID: userID)

        // Pre-write persisted session.
        let store = SupabaseSessionStore(at: tempDir)
        try store.write(PersistedSession(refreshToken: "old-rt", userID: userID, savedAtMs: 1_000))

        let lock = NSLock()
        var paths: [String] = []
        MockURLProtocol.handler = { request, _ in
            lock.lock(); paths.append(request.url?.path ?? ""); lock.unlock()
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/token":
                // Verify refresh_token came from persisted session.
                let body = request.httpBody ?? request.bodyStreamAsData()
                let bodyStr = String(data: body, encoding: .utf8) ?? ""
                XCTAssertTrue(bodyStr.contains("old-rt"), "expected old-rt in body, got: \(bodyStr)")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "\(jwt)", "refresh_token": "new-rt",
                          "user": { "id": "\(userID)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            default:
                XCTFail("unexpected path \(path) — should ONLY hit /auth/v1/token")
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity(),
            sessionStore: store
        )
        let session = try await client.ensureAuthenticated()
        XCTAssertEqual(session.refreshToken, "new-rt")
        XCTAssertEqual(session.pubkeyClaim, pubkey)

        // Only token endpoint hit; no signup / register.
        XCTAssertEqual(paths, ["/auth/v1/token"])

        // Persisted session updated to new refresh_token.
        let persisted = try store.read()
        XCTAssertEqual(persisted?.refreshToken, "new-rt")
    }

    // MARK: - Persisted session refresh fails → falls through to fresh signup

    func testPersistedSession_RefreshFails_FallsThroughToFreshSignup() async throws {
        let pubkey = String(repeating: "42", count: 32)
        let userID = "00000000-0000-0000-0000-000000000ccc"
        let jwt = makeJWT(pubkey: pubkey, userID: userID)

        let store = SupabaseSessionStore(at: tempDir)
        try store.write(PersistedSession(refreshToken: "expired-rt", userID: userID, savedAtMs: 1_000))

        let lock = NSLock()
        var calls = 0
        MockURLProtocol.handler = { request, _ in
            lock.lock(); calls += 1; let attempt = calls; lock.unlock()
            let path = request.url?.path ?? ""

            switch path {
            case "/auth/v1/token":
                // First call uses persisted refresh → 401 (expired).
                // Second call is part of fresh-signup flow → should succeed.
                if attempt == 1 {
                    return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                            Data())
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "\(jwt)", "refresh_token": "new-after-fallback",
                          "user": { "id": "\(userID)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "fresh-tok", "refresh_token": "fresh-rt",
                          "user": { "id": "\(userID)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            default:
                XCTFail("unexpected path \(path)")
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity(),
            sessionStore: store
        )
        let session = try await client.ensureAuthenticated()
        XCTAssertEqual(session.refreshToken, "new-after-fallback")

        // Persisted session updated to refreshed token from fresh signup flow.
        let persisted = try store.read()
        XCTAssertEqual(persisted?.refreshToken, "new-after-fallback")
    }

    // MARK: - sessionStore nil → no behavior change (legacy callers)

    func testNoSessionStore_BackwardsCompatible() async throws {
        let pubkey = String(repeating: "42", count: 32)
        let userID = "00000000-0000-0000-0000-000000000ddd"
        let jwt = makeJWT(pubkey: pubkey, userID: userID)

        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "tok", "refresh_token": "rt",
                          "user": { "id": "\(userID)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "\(jwt)", "refresh_token": "rt2",
                          "user": { "id": "\(userID)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
            // no sessionStore
        )
        let session = try await client.ensureAuthenticated()
        XCTAssertEqual(session.refreshToken, "rt2")
    }
}

// Helper for capturing body from URLRequest streams (MockURLProtocol scenarios where
// httpBody is consumed and only bodyStream remains).
extension URLRequest {
    fileprivate func bodyStreamAsData() -> Data {
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 1024
        var buf = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}
