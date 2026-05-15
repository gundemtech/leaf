// Phase Track-5 S5 — SupabaseClient team_events endpoints coverage.

import XCTest
import CryptoKit
@testable import LeafCore

/// Thread-safe single-slot value box for capturing data inside Sendable closures.
private final class SyncBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ initial: T) { self.value = initial }
    func set(_ v: T) { lock.lock(); defer { lock.unlock() }; value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

final class SupabaseClientTeamEventsTests: XCTestCase {
    private let baseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "test-anon-key"
    private let pubkey = String(repeating: "42", count: 32)
    private let userID = "00000000-0000-0000-0000-000000000fff"

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

    private func makeJWT() -> String {
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"pubkey":"\#(pubkey)","sub":"\#(userID)"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).sig"
    }

    private func wrapWithBootstrap(_ handler: @escaping @Sendable (URLRequest, Data) -> (HTTPURLResponse, Data)) -> (@Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)) {
        let jwt = makeJWT()
        let uid = userID
        return { request, body in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "boot-tok", "refresh_token": "boot-rt",
                          "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "\(jwt)", "refresh_token": "ref",
                          "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            default:
                return handler(request, body)
            }
        }
    }

    private func makeClient() -> SupabaseClient {
        SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
    }

    // MARK: - sendTeamEvent

    func testSendTeamEvent_Success_ReturnsRow() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            XCTAssertEqual(request.url?.path, "/rest/v1/team_events")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "return=representation")
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data("""
                    [{ "event_id": "evt-1", "created_at": "2026-05-15T10:00:00Z" }]
                    """.utf8))
        }
        let client = makeClient()
        let result = try await client.sendTeamEvent(
            workspaceID: "ws-1",
            eventID: "evt-1",
            sourceKind: "git_commits",
            kind: "gh_commit_pushed",
            encryptedPayload: Data([0xAB, 0xCD]),
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(result.eventID, "evt-1")
        XCTAssertEqual(result.createdAtISO, "2026-05-15T10:00:00Z")
    }

    func testSendTeamEvent_403RLSForbidden_Throws() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"message":"insufficient privilege"}"#.utf8))
        }
        let client = makeClient()
        do {
            _ = try await client.sendTeamEvent(
                workspaceID: "ws-1",
                eventID: "evt-1",
                sourceKind: "git_commits",
                kind: "gh_commit_pushed",
                encryptedPayload: Data(),
                expiresAt: Date()
            )
            XCTFail("expected throw")
        } catch _ as SupabaseError {
            // pass
        }
    }

    func testSendTeamEvent_BodyContainsAllFieldsIncludingExpiresAt() async throws {
        let captured = SyncBox<Data?>(nil)
        MockURLProtocol.handler = wrapWithBootstrap { [captured] request, body in
            if request.url?.path == "/rest/v1/team_events" {
                captured.set(body)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data(#"[{ "event_id": "evt-1", "created_at": "2026-05-15T10:00:00Z" }]"#.utf8))
        }
        let client = makeClient()
        _ = try await client.sendTeamEvent(
            workspaceID: "ws-1",
            eventID: "evt-1",
            sourceKind: "linear_issues",
            kind: "issue_updated",
            encryptedPayload: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let body = try XCTUnwrap(captured.get())
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        XCTAssertEqual(json["event_id"] as? String, "evt-1")
        XCTAssertEqual(json["workspace_id"] as? String, "ws-1")
        XCTAssertEqual(json["source_kind"] as? String, "linear_issues")
        XCTAssertEqual(json["kind"] as? String, "issue_updated")
        XCTAssertEqual(json["sender_pubkey"] as? String, pubkey)
        XCTAssertEqual(json["encrypted_payload"] as? String, "\\xdeadbeef")
        XCTAssertNotNil(json["expires_at"] as? String)
    }

    // MARK: - fetchInboundTeamEvents

    func testFetchInboundTeamEvents_ColdBootstrap_NoSinceParam() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            XCTAssertEqual(request.url?.path, "/rest/v1/team_events")
            XCTAssertEqual(request.httpMethod, "GET")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("workspace_id=eq.ws-1"))
            XCTAssertFalse(query.contains("created_at=gt"))   // cold bootstrap omits since
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("[]".utf8))
        }
        let client = makeClient()
        let rows = try await client.fetchInboundTeamEvents(
            workspaceID: "ws-1", sinceCreatedAtMs: nil, limit: 100
        )
        XCTAssertEqual(rows.count, 0)
    }

    func testFetchInboundTeamEvents_IncrementalSinceParam_Encoded() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("created_at=gt."), "since watermark must encode: \(query)")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("[]".utf8))
        }
        let client = makeClient()
        _ = try await client.fetchInboundTeamEvents(
            workspaceID: "ws-1", sinceCreatedAtMs: 1_700_000_000_000, limit: 100
        )
    }

    func testFetchInboundTeamEvents_ParsesRowFields_AndDecodesBytea() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("""
                    [
                      {
                        "event_id": "evt-1",
                        "workspace_id": "ws-1",
                        "sender_pubkey": "abcd",
                        "source_kind": "git_commits",
                        "kind": "gh_commit_pushed",
                        "encrypted_payload": "\\\\xdeadbeef",
                        "created_at": "2026-05-15T10:00:00Z",
                        "expires_at": "2026-06-14T10:00:00Z"
                      }
                    ]
                    """.utf8))
        }
        let client = makeClient()
        let rows = try await client.fetchInboundTeamEvents(
            workspaceID: "ws-1", sinceCreatedAtMs: nil, limit: 100
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].eventID, "evt-1")
        XCTAssertEqual(rows[0].sourceKind, "git_commits")
        XCTAssertEqual(rows[0].kind, "gh_commit_pushed")
        XCTAssertEqual(rows[0].encryptedPayload, Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertGreaterThan(rows[0].createdAtMs, 0)
    }

    func testFetchInboundTeamEvents_401Unauthorized_Throws() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"message":"invalid jwt"}"#.utf8))
        }
        let client = makeClient()
        do {
            _ = try await client.fetchInboundTeamEvents(workspaceID: "ws-1", sinceCreatedAtMs: nil, limit: 100)
            XCTFail("expected throw")
        } catch _ as SupabaseError {
            // pass
        }
    }
}
