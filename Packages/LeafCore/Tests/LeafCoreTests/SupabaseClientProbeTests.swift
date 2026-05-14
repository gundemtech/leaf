import XCTest
import CryptoKit
@testable import LeafCore

final class SupabaseClientProbeTests: XCTestCase {
    private let baseURL = URL(string: "https://test.supabase.co")!

    override func tearDown() async throws { MockURLProtocol.handler = nil }

    private func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: c)
    }

    private func makeClient() -> SupabaseClient {
        SupabaseClient(baseURL: baseURL, anonKey: "k", urlSession: makeSession(),
                       identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)) })
    }

    func testProbe_pending() async throws {
        MockURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.path, "/functions/v1/invite_resolve")
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["probe"] as? Bool, true)
            let resp = """
            { "status": "pending", "claimed_at": null, "claimed_by_pubkey": null,
              "expires_at": "2026-05-16T00:00:00Z" }
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, resp)
        }
        let client = makeClient()
        let status = try await client.probeInvite(token: "33333333-3333-3333-3333-333333333333")
        XCTAssertEqual(status, .pending)
    }

    func testProbe_claimed() async throws {
        MockURLProtocol.handler = { request, _ in
            let resp = """
            { "status": "claimed", "claimed_at": "2026-05-15T12:00:00Z", "claimed_by_pubkey": "ee",
              "expires_at": "2026-05-16T00:00:00Z" }
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, resp)
        }
        let client = makeClient()
        let status = try await client.probeInvite(token: "33333333-3333-3333-3333-333333333333")
        if case .claimed(let by, let at) = status {
            XCTAssertEqual(by, "ee")
            XCTAssertEqual(at, "2026-05-15T12:00:00Z")
        } else {
            XCTFail("expected .claimed got \(status)")
        }
    }

    func testProbe_expired() async throws {
        MockURLProtocol.handler = { request, _ in
            let resp = """
            { "status": "expired", "claimed_at": null, "claimed_by_pubkey": null,
              "expires_at": "2026-05-15T00:00:00Z" }
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, resp)
        }
        let client = makeClient()
        let status = try await client.probeInvite(token: "33333333-3333-3333-3333-333333333333")
        XCTAssertEqual(status, .expired)
    }

    func testProbe_notFound() async throws {
        MockURLProtocol.handler = { request, _ in
            let resp = #"{ "status": "not_found" }"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, resp)
        }
        let client = makeClient()
        let status = try await client.probeInvite(token: "33333333-3333-3333-3333-333333333333")
        XCTAssertEqual(status, .notFound)
    }
}
