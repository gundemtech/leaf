// Track 5 / S6 — SupabaseClient cross-post (Slack + Linear) endpoint coverage.
//
// Mirrors SupabaseClientDirectMessagesTests pattern: MockURLProtocol with a
// bootstrap-wrapped handler so the actor's ensureAuthenticated() succeeds
// before the cross-post call under test fires its own HTTP request.

import XCTest
import CryptoKit
@testable import LeafCore

final class SupabaseClientCrossPostTests: XCTestCase {
    private let baseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "test-anon-key"
    private let pubkey = String(repeating: "42", count: 32)
    private let userID = "00000000-0000-0000-0000-000000000fff"
    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let messageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let idempotencyKey = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

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

    private func makeJWT(includePubkeyClaim: Bool = true) -> String {
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payload: String
        if includePubkeyClaim {
            payload = #"{"pubkey":"\#(pubkey)","sub":"\#(userID)"}"#
        } else {
            payload = #"{"sub":"\#(userID)"}"#
        }
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).sig"
    }

    /// Common bootstrap handler — handles signup + register + refresh sequence so
    /// the actor's `ensureAuthenticated` succeeds before specific cross-post call.
    /// Pass includePubkeyClaim=false to simulate Auth Hook race / decode glitch.
    private func wrapWithBootstrap(
        includePubkeyClaim: Bool = true,
        _ next: @escaping @Sendable (URLRequest, Data) -> (HTTPURLResponse, Data)
    ) -> (@Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)) {
        let jwt = makeJWT(includePubkeyClaim: includePubkeyClaim)
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
                return next(request, body)
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

    /// Inline-and-fresh sample payload — declared as `static` so each call-site
    /// constructs a brand-new value (region-disjoint from `self`), satisfying
    /// the actor-isolated `sending [String: Any]` parameter without races.
    private static func makeSampleSlackPayload() -> [String: Any] {
        [
            "channel": "C12345",
            "text": "Hello from Leaf",
            "blocks": [
                ["type": "section",
                 "text": ["type": "mrkdwn", "text": "Hello from Leaf"]],
            ],
            "unfurl_links": false,
            "unfurl_media": false,
        ]
    }

    // MARK: - triggerSlackPost

    func testTriggerSlackPost_Success_ReturnsResult() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            XCTAssertEqual(request.url?.path, "/functions/v1/slack_post")
            XCTAssertEqual(request.httpMethod, "POST")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true,"ts":"1234.5678","channel_id":"C12345"}"#.utf8))
        }
        let client = makeClient()
        let result = try await client.triggerSlackPost(
            workspaceID: workspaceID,
            messageID: messageID,
            channelID: "C12345",
            slackPayload: Self.makeSampleSlackPayload(),
            slackUserToken: "xoxp-test-token"
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.ts, "1234.5678")
        XCTAssertEqual(result.channelID, "C12345")
        XCTAssertNil(result.error)
        XCTAssertNil(result.retryAfterSeconds)
    }

    func testTriggerSlackPost_ErrorPath_PreservesErrorCode() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":false,"error":"channel_not_found"}"#.utf8))
        }
        let client = makeClient()
        let result = try await client.triggerSlackPost(
            workspaceID: workspaceID,
            messageID: messageID,
            channelID: "Cmissing",
            slackPayload: Self.makeSampleSlackPayload(),
            slackUserToken: "xoxp-test-token"
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, "channel_not_found")
        XCTAssertNil(result.ts)
        XCTAssertNil(result.retryAfterSeconds)
    }

    func testTriggerSlackPost_RateLimited_RetryAfterPassthrough() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":false,"error":"rate_limited","retry_after_seconds":5}"#.utf8))
        }
        let client = makeClient()
        let result = try await client.triggerSlackPost(
            workspaceID: workspaceID,
            messageID: messageID,
            channelID: "C12345",
            slackPayload: Self.makeSampleSlackPayload(),
            slackUserToken: "xoxp-test-token"
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, "rate_limited")
        XCTAssertEqual(result.retryAfterSeconds, 5)
    }

    func testTriggerSlackPost_MissingPubkeyClaim_Throws() async throws {
        MockURLProtocol.handler = wrapWithBootstrap(includePubkeyClaim: false) { request, _ in
            // Should never reach this — guard fires before HTTP call.
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true}"#.utf8))
        }
        let client = makeClient()
        do {
            _ = try await client.triggerSlackPost(
                workspaceID: workspaceID,
                messageID: messageID,
                channelID: "C12345",
                slackPayload: Self.makeSampleSlackPayload(),
                slackUserToken: "xoxp-test-token"
            )
            XCTFail("expected throw")
        } catch SupabaseError.identityClaimMissing {
            // pass
        } catch {
            XCTFail("expected .identityClaimMissing, got \(error)")
        }
    }

    func testTriggerSlackPost_401_ThrowsUnauthorized() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"error":"unauthorized"}"#.utf8))
        }
        let client = makeClient()
        do {
            _ = try await client.triggerSlackPost(
                workspaceID: workspaceID,
                messageID: messageID,
                channelID: "C12345",
                slackPayload: Self.makeSampleSlackPayload(),
                slackUserToken: "xoxp-test-token"
            )
            XCTFail("expected throw")
        } catch SupabaseError.unauthorized {
            // pass
        } catch {
            XCTFail("expected .unauthorized, got \(error)")
        }
    }

    func testTriggerSlackPost_RequestBodyShape() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, body in
            // Validate Authorization Bearer + Content-Type.
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            XCTAssertTrue(auth.hasPrefix("Bearer "), "Authorization header should be Bearer JWT, got: \(auth)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            // Decode the body and inspect keys.
            guard let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                XCTFail("body not valid JSON object")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            }
            XCTAssertEqual(parsed["workspace_id"] as? String, "11111111-1111-1111-1111-111111111111")
            XCTAssertEqual(parsed["message_id"] as? String, "22222222-2222-2222-2222-222222222222")
            XCTAssertEqual(parsed["channel_id"] as? String, "C12345")
            XCTAssertEqual(parsed["slack_user_token"] as? String, "xoxp-test-token")
            // slack_payload must be a nested dict, not a stringified blob.
            XCTAssertNotNil(parsed["slack_payload"] as? [String: Any], "slack_payload must be nested JSON object")
            let nested = parsed["slack_payload"] as? [String: Any]
            XCTAssertEqual(nested?["channel"] as? String, "C12345")
            XCTAssertEqual(nested?["text"] as? String, "Hello from Leaf")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true,"ts":"1.2","channel_id":"C12345"}"#.utf8))
        }
        let client = makeClient()
        _ = try await client.triggerSlackPost(
            workspaceID: workspaceID,
            messageID: messageID,
            channelID: "C12345",
            slackPayload: Self.makeSampleSlackPayload(),
            slackUserToken: "xoxp-test-token"
        )
    }

    // MARK: - triggerLinearCreate

    func testTriggerLinearCreate_Success_ReturnsResult() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            XCTAssertEqual(request.url?.path, "/functions/v1/linear_create_issue")
            XCTAssertEqual(request.httpMethod, "POST")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"""
                    {"ok":true,"issue_id":"ISSUE-uuid-1","identifier":"LEA-42","url":"https://linear.app/leaf/issue/LEA-42/title"}
                    """#.utf8))
        }
        let client = makeClient()
        let result = try await client.triggerLinearCreate(
            workspaceID: workspaceID,
            messageID: messageID,
            teamID: "team-1",
            idempotencyKey: idempotencyKey,
            title: "Crash on launch",
            description: "Found a bug",
            assigneeID: nil,
            linearUserToken: "lin_api_test"
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.issueID, "ISSUE-uuid-1")
        XCTAssertEqual(result.identifier, "LEA-42")
        XCTAssertEqual(result.url, "https://linear.app/leaf/issue/LEA-42/title")
        XCTAssertNil(result.error)
    }

    func testTriggerLinearCreate_ErrorPath_PreservesErrorCode() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":false,"error":"authentication_error"}"#.utf8))
        }
        let client = makeClient()
        let result = try await client.triggerLinearCreate(
            workspaceID: workspaceID,
            messageID: messageID,
            teamID: "team-1",
            idempotencyKey: idempotencyKey,
            title: "Title",
            description: "Desc",
            assigneeID: nil,
            linearUserToken: "lin_api_test"
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, "authentication_error")
        XCTAssertNil(result.issueID)
    }

    func testTriggerLinearCreate_IdempotencyKeyInBody() async throws {
        let key = idempotencyKey
        MockURLProtocol.handler = wrapWithBootstrap { request, body in
            guard let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                XCTFail("body not valid JSON object")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            }
            XCTAssertEqual(parsed["idempotency_key"] as? String, key.uuidString.lowercased())
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true,"issue_id":"X","identifier":"LEA-1","url":"https://linear.app/x"}"#.utf8))
        }
        let client = makeClient()
        _ = try await client.triggerLinearCreate(
            workspaceID: workspaceID,
            messageID: messageID,
            teamID: "team-1",
            idempotencyKey: key,
            title: "T",
            description: "D",
            assigneeID: nil,
            linearUserToken: "lin_test"
        )
    }

    func testTriggerLinearCreate_AssigneeNil_OmittedFromBody() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, body in
            guard let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                XCTFail("body not valid JSON object")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            }
            XCTAssertFalse(parsed.keys.contains("assignee_id"),
                           "assignee_id MUST be omitted (not null) when assigneeID is nil — got keys: \(parsed.keys.sorted())")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true,"issue_id":"X","identifier":"LEA-1","url":"https://linear.app/x"}"#.utf8))
        }
        let client = makeClient()
        _ = try await client.triggerLinearCreate(
            workspaceID: workspaceID,
            messageID: messageID,
            teamID: "team-1",
            idempotencyKey: idempotencyKey,
            title: "T",
            description: "D",
            assigneeID: nil,
            linearUserToken: "lin_test"
        )
    }

    func testTriggerLinearCreate_AssigneePresent_InBody() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, body in
            guard let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                XCTFail("body not valid JSON object")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            }
            XCTAssertEqual(parsed["assignee_id"] as? String, "user-abc")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true,"issue_id":"X","identifier":"LEA-1","url":"https://linear.app/x"}"#.utf8))
        }
        let client = makeClient()
        _ = try await client.triggerLinearCreate(
            workspaceID: workspaceID,
            messageID: messageID,
            teamID: "team-1",
            idempotencyKey: idempotencyKey,
            title: "T",
            description: "D",
            assigneeID: "user-abc",
            linearUserToken: "lin_test"
        )
    }

    func testTriggerLinearCreate_500_ThrowsServerError() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeClient()
        do {
            _ = try await client.triggerLinearCreate(
                workspaceID: workspaceID,
                messageID: messageID,
                teamID: "team-1",
                idempotencyKey: idempotencyKey,
                title: "T",
                description: "D",
                assigneeID: nil,
                linearUserToken: "lin_test"
            )
            XCTFail("expected throw")
        } catch SupabaseError.serverError {
            // pass
        } catch {
            XCTFail("expected .serverError, got \(error)")
        }
    }

    func testTriggerLinearCreate_MissingPubkeyClaim_Throws() async throws {
        MockURLProtocol.handler = wrapWithBootstrap(includePubkeyClaim: false) { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true}"#.utf8))
        }
        let client = makeClient()
        do {
            _ = try await client.triggerLinearCreate(
                workspaceID: workspaceID,
                messageID: messageID,
                teamID: "team-1",
                idempotencyKey: idempotencyKey,
                title: "T",
                description: "D",
                assigneeID: nil,
                linearUserToken: "lin_test"
            )
            XCTFail("expected throw")
        } catch SupabaseError.identityClaimMissing {
            // pass
        } catch {
            XCTFail("expected .identityClaimMissing, got \(error)")
        }
    }

    func testTriggerLinearCreate_AuthorizationBearerJWTHeader() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            XCTAssertTrue(auth.hasPrefix("Bearer "), "expected Bearer prefix, got: \(auth)")
            XCTAssertTrue(auth.count > 10, "JWT should be reasonably long")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true,"issue_id":"X","identifier":"LEA-1","url":"https://linear.app/x"}"#.utf8))
        }
        let client = makeClient()
        _ = try await client.triggerLinearCreate(
            workspaceID: workspaceID,
            messageID: messageID,
            teamID: "team-1",
            idempotencyKey: idempotencyKey,
            title: "T",
            description: "D",
            assigneeID: nil,
            linearUserToken: "lin_test"
        )
    }
}
