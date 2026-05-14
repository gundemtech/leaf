import XCTest
import CryptoKit
@testable import LeafCore

final class SupabaseClientAuthBootstrapTests: XCTestCase {
    private let baseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "test-anon-key"

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
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

    func testSignInAnonymously_success_returnsSession() async throws {
        let stubBody = """
        {
          "access_token": "eyJxxx.aaa.bbb",
          "refresh_token": "refresh-xyz",
          "user": { "id": "00000000-0000-0000-0000-000000000111" },
          "expires_at": 9999999999
        }
        """.data(using: .utf8)!
        MockURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.absoluteString, "https://test.supabase.co/auth/v1/signup")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-anon-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, stubBody)
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
        let session = try await client.performSignInAnonymouslyForTesting()
        XCTAssertEqual(session.accessToken, "eyJxxx.aaa.bbb")
        XCTAssertEqual(session.refreshToken, "refresh-xyz")
        XCTAssertEqual(session.userID, UUID(uuidString: "00000000-0000-0000-0000-000000000111"))
        XCTAssertNil(session.pubkeyClaim)
    }

    func testSignInAnonymously_401_throwsUnauthorized() async throws {
        MockURLProtocol.handler = { request, _ in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
        do {
            _ = try await client.performSignInAnonymouslyForTesting()
            XCTFail("expected throw")
        } catch let error as SupabaseError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testSignInAnonymously_malformedBody_throwsDecoding() async throws {
        MockURLProtocol.handler = { request, _ in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("not json".utf8))
        }
        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
        do {
            _ = try await client.performSignInAnonymouslyForTesting()
            XCTFail("expected throw")
        } catch let error as SupabaseError {
            if case .decoding = error { /* pass */ } else { XCTFail("expected .decoding got \(error)") }
        }
    }

    // MARK: - ensureAuthenticated() — full bootstrap

    private func makeJWT(pubkey: String, userID: String = "00000000-0000-0000-0000-000000000222") -> String {
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

    private func bodyJSON(_ raw: String) -> Data { raw.data(using: .utf8)! }

    func testEnsureAuthenticated_fullBootstrap_signupRegisterRefresh() async throws {
        let expectedPubkey = String(repeating: "42", count: 32)
        let refreshedJWT = makeJWT(pubkey: expectedPubkey)
        let lock = NSLock()
        var callPaths: [String] = []

        MockURLProtocol.handler = { request, _ in
            lock.lock(); callPaths.append(request.url?.path ?? ""); lock.unlock()
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                let body = self.bodyJSON("""
                {
                  "access_token": "tok-1",
                  "refresh_token": "ref-1",
                  "user": { "id": "00000000-0000-0000-0000-000000000222" },
                  "expires_at": 9999999999
                }
                """)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            case "/functions/v1/register_pubkey":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        self.bodyJSON(#"{ "ok": true, "idempotent": false }"#))
            case "/auth/v1/token":
                let body = self.bodyJSON("""
                {
                  "access_token": "\(refreshedJWT)",
                  "refresh_token": "ref-2",
                  "user": { "id": "00000000-0000-0000-0000-000000000222" },
                  "expires_at": 9999999999
                }
                """)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            default:
                XCTFail("unexpected url \(path)")
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
        let session = try await client.ensureAuthenticated()
        XCTAssertEqual(session.accessToken, refreshedJWT)
        XCTAssertEqual(session.refreshToken, "ref-2")
        XCTAssertEqual(session.pubkeyClaim, expectedPubkey)
        XCTAssertEqual(callPaths, [
            "/auth/v1/signup",
            "/functions/v1/register_pubkey",
            "/auth/v1/token",
        ])
    }

    func testEnsureAuthenticated_secondCall_returnsCachedSession() async throws {
        let expectedPubkey = String(repeating: "42", count: 32)
        let refreshedJWT = makeJWT(pubkey: expectedPubkey, userID: "00000000-0000-0000-0000-000000000333")
        let lock = NSLock()
        var callCount = 0

        MockURLProtocol.handler = { request, _ in
            lock.lock(); callCount += 1; lock.unlock()
            let path = request.url?.path ?? ""
            if path == "/auth/v1/signup" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        self.bodyJSON("""
                        { "access_token": "tok", "refresh_token": "ref",
                          "user": { "id": "00000000-0000-0000-0000-000000000333" },
                          "expires_at": 9999999999 }
                        """))
            }
            if path == "/functions/v1/register_pubkey" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        self.bodyJSON(#"{ "ok": true }"#))
            }
            if path == "/auth/v1/token" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        self.bodyJSON("""
                        { "access_token": "\(refreshedJWT)", "refresh_token": "ref2",
                          "user": { "id": "00000000-0000-0000-0000-000000000333" },
                          "expires_at": 9999999999 }
                        """))
            }
            XCTFail("unexpected path \(path)")
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
        _ = try await client.ensureAuthenticated()
        XCTAssertEqual(callCount, 3)
        _ = try await client.ensureAuthenticated()
        XCTAssertEqual(callCount, 3, "second ensureAuthenticated must reuse cached session")
    }

    func testEnsureAuthenticated_concurrentCalls_shareInFlightTask() async throws {
        let expectedPubkey = String(repeating: "42", count: 32)
        let refreshedJWT = makeJWT(pubkey: expectedPubkey, userID: "00000000-0000-0000-0000-000000000444")
        let lock = NSLock()
        var callCount = 0

        MockURLProtocol.handler = { request, _ in
            lock.lock(); callCount += 1; lock.unlock()
            let path = request.url?.path ?? ""
            if path == "/auth/v1/signup" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        self.bodyJSON("""
                        { "access_token": "tok", "refresh_token": "ref",
                          "user": { "id": "00000000-0000-0000-0000-000000000444" },
                          "expires_at": 9999999999 }
                        """))
            }
            if path == "/functions/v1/register_pubkey" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        self.bodyJSON(#"{ "ok": true }"#))
            }
            if path == "/auth/v1/token" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        self.bodyJSON("""
                        { "access_token": "\(refreshedJWT)", "refresh_token": "ref2",
                          "user": { "id": "00000000-0000-0000-0000-000000000444" },
                          "expires_at": 9999999999 }
                        """))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
        async let s1 = client.ensureAuthenticated()
        async let s2 = client.ensureAuthenticated()
        let (session1, session2) = try await (s1, s2)
        XCTAssertEqual(session1.accessToken, refreshedJWT)
        XCTAssertEqual(session2.accessToken, refreshedJWT)
        XCTAssertEqual(callCount, 3, "concurrent calls must share bootstrap; not 6 round-trips")
    }

    func testEnsureAuthenticated_registerPubkey409_TOFUCollision() async throws {
        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            if path == "/auth/v1/signup" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        self.bodyJSON("""
                        { "access_token": "tok", "refresh_token": "ref",
                          "user": { "id": "00000000-0000-0000-0000-000000000555" },
                          "expires_at": 9999999999 }
                        """))
            }
            if path == "/functions/v1/register_pubkey" {
                return (HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!,
                        self.bodyJSON(#"{ "error": "pubkey_already_registered" }"#))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
        do {
            _ = try await client.ensureAuthenticated()
            XCTFail("expected throw")
        } catch let error as SupabaseError {
            XCTAssertEqual(error, .pubkeyAlreadyRegistered)
        }
    }
}
