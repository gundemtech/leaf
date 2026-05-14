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
}
