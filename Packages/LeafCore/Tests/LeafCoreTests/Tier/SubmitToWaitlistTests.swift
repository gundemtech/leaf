//
//  SubmitToWaitlistTests.swift
//  LeafCoreTests
//
//  Track 5 / S8 / T4 — verifies SupabaseClient.submitToWaitlist behaviour.
//  Covers HTTP 201/204 success, 409 duplicate idempotency, 4xx/5xx mapping,
//  and the email normalization invariant.
//

import XCTest
import CryptoKit
@testable import LeafCore

final class SubmitToWaitlistTests: XCTestCase {
    private let baseURL = URL(string: "https://test.supabase.co")!

    override func tearDown() async throws { MockURLProtocol.handler = nil }

    private func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: c)
    }

    private func makeClient(session: URLSession) -> SupabaseClient {
        SupabaseClient(
            baseURL: baseURL,
            anonKey: "test-anon-key",
            urlSession: session,
            identity: {
                try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xAA, count: 32))
            }
        )
    }

    // MARK: - 201 + 204 success paths

    func testSubmitToWaitlist_201Created_ReturnsSuccess() async throws {
        MockURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.path, "/rest/v1/waitlist")
            XCTAssertEqual(request.httpMethod, "POST")
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = makeClient(session: makeSession())
        let result = await client.submitToWaitlist(email: "alice@example.com")
        if case .failure(let err) = result {
            XCTFail("Expected success; got \(err)")
        }
    }

    func testSubmitToWaitlist_204NoContent_ReturnsSuccess() async throws {
        MockURLProtocol.handler = { request, _ in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = makeClient(session: makeSession())
        let result = await client.submitToWaitlist(email: "bob@example.com")
        if case .failure(let err) = result {
            XCTFail("Expected success on 204; got \(err)")
        }
    }

    // MARK: - 409 idempotency

    func testSubmitToWaitlist_409Conflict_ReturnsSuccess() async throws {
        MockURLProtocol.handler = { request, _ in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"code":"23505","message":"duplicate key value violates unique constraint \"waitlist_pkey\""}"#.utf8))
        }
        let client = makeClient(session: makeSession())
        let result = await client.submitToWaitlist(email: "alice@example.com")
        if case .failure(let err) = result {
            XCTFail("Expected duplicate email to be idempotent success; got \(err)")
        }
    }

    // MARK: - Failure paths

    func testSubmitToWaitlist_500Error_ReturnsFailure() async throws {
        MockURLProtocol.handler = { request, _ in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = makeClient(session: makeSession())
        let result = await client.submitToWaitlist(email: "alice@example.com")
        switch result {
        case .success:
            XCTFail("Expected failure on 500")
        case .failure(let err):
            XCTAssertEqual(err as? SupabaseError, .serverError)
        }
    }

    func testSubmitToWaitlist_400BadRequest_ReturnsFailure() async throws {
        MockURLProtocol.handler = { request, _ in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = makeClient(session: makeSession())
        let result = await client.submitToWaitlist(email: "bad-email")
        switch result {
        case .success:
            XCTFail("Expected failure on 400")
        case .failure(let err):
            XCTAssertEqual(err as? SupabaseError, .badRequest)
        }
    }

    // MARK: - Empty email guard

    func testSubmitToWaitlist_EmptyEmail_FailsWithoutHTTPCall() async throws {
        var sawCall = false
        MockURLProtocol.handler = { _, _ in
            sawCall = true
            return (HTTPURLResponse(url: URL(string: "x")!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = makeClient(session: makeSession())
        let result = await client.submitToWaitlist(email: "   ")
        XCTAssertFalse(sawCall, "Empty email should short-circuit without an HTTP call")
        switch result {
        case .success: XCTFail("Expected failure on empty email")
        case .failure(let err): XCTAssertEqual(err as? SupabaseError, .badRequest)
        }
    }

    // MARK: - Email + source body shape

    func testSubmitToWaitlist_BodyContainsLowercasedEmailAndSource() async throws {
        var capturedBody: Data?
        var capturedAuth: String?
        MockURLProtocol.handler = { request, body in
            capturedBody = body
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = makeClient(session: makeSession())
        let _ = await client.submitToWaitlist(email: "  ALICE@Example.COM  ", source: "test_source")

        // Anon path: no Authorization header — only apikey is needed for RLS WITH CHECK(true).
        XCTAssertNil(capturedAuth, "submitToWaitlist must NOT send Authorization header — anonymous flow")

        guard let body = capturedBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            XCTFail("Body not captured / not JSON"); return
        }
        XCTAssertEqual(json["email"] as? String, "alice@example.com",
                       "email must be trimmed + lowercased before send")
        XCTAssertEqual(json["source"] as? String, "test_source")
    }

    func testSubmitToWaitlist_DefaultSourceIsUpgradeModal() async throws {
        var capturedBody: Data?
        MockURLProtocol.handler = { request, body in
            capturedBody = body
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = makeClient(session: makeSession())
        let _ = await client.submitToWaitlist(email: "carol@example.com")
        guard let body = capturedBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            XCTFail("Body not captured"); return
        }
        XCTAssertEqual(json["source"] as? String, "upgrade_modal",
                       "Default source must match server-side spec §10.3")
    }
}
