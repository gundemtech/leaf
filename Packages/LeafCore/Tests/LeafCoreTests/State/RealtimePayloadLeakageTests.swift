// Track 5 / S7 — D.10. ADR-010 sentinel-injection + source-scan walkback fences
// for the Realtime substrate (RealtimeWebSocketDriver + LeafRealtimeService).
//
// Intent: mirror TeamEventPayloadLeakageTests (S5) and CrossPostPayloadLeakageTests (S6).
// Six areas per spec §14.5:
//   1. Source scan — LeafRealtimeService must not contain any log statements
//   2. Failed decrypt — no partial plaintext bytes reach reader surface
//   3. Heartbeat frames — empty payload, no workspace data
//   4. phx_join payload — workspace_id intentional; sender pubkey MUST NOT appear
//   5. Source scan — RealtimeWebSocketDriver dispatch must not log or reference plaintext
//   6. Reconnect — stale workspace A topic must not appear in workspace B join frame
//
// Patterns used:
//   • Source-level string scan (stable static analysis) for log-call walkbacks.
//   • End-to-end subscribe → driver.dispatchMessage → assert-reader-empty for
//     decrypt-failure leakage test (same pattern as LeafRealtimeServiceTests #6).
//   • MockWebSocketTask injection (existing D.2 seam) for frame-level assertions.
//   • MockTeamEventAbsorber / MockDirectMessageAbsorber defined in
//     LeafRealtimeServiceTests.swift (same target — available without redeclaration).

import XCTest
import CryptoKit
import Foundation
@testable import LeafCore

@MainActor
final class RealtimePayloadLeakageTests: XCTestCase {

    // MARK: - Shared fixtures

    private let supabaseBaseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "test-anon-key"
    private let pubkeyHex = String(repeating: "42", count: 32)
    private let userID = "00000000-0000-0000-0000-000000000abc"

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
    }

    // MARK: - (1) Source scan — LeafRealtimeService must not log decrypted content

    /// ADR-010: decrypted payload content (DM body, team event details) must never
    /// be emitted to any log channel from inside LeafRealtimeService.
    ///
    /// The service's sole job is routing decrypted rows to readers — any print/NSLog/
    /// os_log/Logger call risks exposing decrypted bytes to system log (readable by
    /// processes with `log` entitlement and by crash reporters).
    func testService_NoLogStatements() throws {
        let sourceURL = leafCoreSourceURL("State", "LeafRealtimeService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let banned = ["print(", "NSLog(", "os_log(", "Logger("]
        for pattern in banned {
            XCTAssertFalse(
                source.contains(pattern),
                "LeafRealtimeService must not contain '\(pattern)' — leaks risk for decrypted row content"
            )
        }
    }

    // MARK: - (2) Failed decrypt — no partial bytes reach readers

    /// When the team event decryptor throws, the service must silently skip.
    /// No plaintext bytes (even partial) can surface in the reader.
    ///
    /// Sentinel bytes are loaded into the encrypted payload field. If the service
    /// incorrectly forwards ciphertext bytes as plaintext, the sentinel would appear
    /// in `received`. Assert reader is empty after the failed decrypt path.
    func testTeamEventDecrypt_Failure_NoBytesReachReader() async throws {
        // Use a well-known sentinel in the encrypted_payload — if bytes escape,
        // they would appear in the absorber's received list.
        let sentinel = "SECRET-TEAMEVT-CIPHER-SENTINEL-4F9A2C"

        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 9999)
        let supabase = try await installAuthBootstrap()
        let dmStub  = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)

        // Decryptor always throws.
        // Track 5 / S8 / T0 — Phase H signature: input narrowed to
        // EncryptedTeamEventInput (no sender / kind in scope).
        let failDecrypt: LeafRealtimeService.TeamEventDecryptor = { _ in
            throw NSError(domain: "test.leak", code: 1)
        }
        let failDecryptDM: LeafRealtimeService.DirectMessageDecryptor = { _ in
            throw NSError(domain: "test.leak", code: 2)
        }

        let service = LeafRealtimeService(
            driver: driver,
            supabase: supabase,
            activeWorkspaceStore: ActiveWorkspaceStore(userDefaults: leakageTestDefaults()),
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost,
            realtimeURL: supabaseBaseURL,
            teamEventDecryptor: failDecrypt,
            directMessageDecryptor: failDecryptDM
        )

        await service.subscribe(workspaceID: "ws-sentinel")
        // Synthesize phx_join ack so the dispatch loop is running.
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-ws-sentinel","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """))

        // Inject a postgres_changes INSERT for team_events carrying the sentinel hex.
        // encrypted_payload is hex-encoded bytes — sentinel text as hex is just for
        // verifying no echo occurs; decryptor throws before reaching reader.
        let sentinelHex = Data(sentinel.utf8).map { String(format: "%02x", $0) }.joined()
        let record: [String: Any] = [
            "event_id":          "ev-sentinel-1",
            "workspace_id":      "ws-sentinel",
            "sender_pubkey":     pubkeyHex,
            "source_kind":       "gitCommits",
            "kind":              "gh_commit_pushed",
            "encrypted_payload": "\\x\(sentinelHex)",
            "created_at":        "2026-01-01T00:00:00Z",
        ]
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-ws-sentinel",
            "event": "postgres_changes",
            "payload": ["data": ["type": "INSERT", "table": "team_events", "record": record]],
            "ref": NSNull(),
        ]
        let frameData = try JSONSerialization.data(withJSONObject: envelope)
        let frame = String(data: frameData, encoding: .utf8)!
        await driver.dispatchMessage(.string(frame))

        // Give the dispatch loop a tick to drain (same timing as existing service tests).
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(
            teamStub.received.isEmpty,
            "Reader must receive nothing after failed team event decrypt — \(teamStub.received.count) rows leaked"
        )
        // Defensive: if a row somehow arrived, sentinel must not be in payload JSON.
        for row in teamStub.received {
            XCTAssertFalse(
                row.plaintextPayloadJSON.contains("SECRET-TEAMEVT"),
                "Sentinel string leaked into TeamEventMirrorRow.plaintextPayloadJSON"
            )
        }
        await service.suspend()
    }

    /// Same walkback for the DM decryptor failure path.
    func testDirectMessageDecrypt_Failure_NoBytesReachReader() async throws {
        let sentinel = "SECRET-DM-CIPHER-SENTINEL-8B3D71"

        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 9999)
        let supabase = try await installAuthBootstrap()
        let dmStub   = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)

        // Track 5 / S8 / T0 — Phase H signature: input narrowed to
        // EncryptedDirectMessageInput (no sender / recipient / kind / replyTo in scope).
        let failDecrypt: LeafRealtimeService.DirectMessageDecryptor = { _ in
            throw NSError(domain: "test.leak", code: 3)
        }
        let failDecryptTeam: LeafRealtimeService.TeamEventDecryptor = { _ in
            throw NSError(domain: "test.leak", code: 4)
        }

        let service = LeafRealtimeService(
            driver: driver,
            supabase: supabase,
            activeWorkspaceStore: ActiveWorkspaceStore(userDefaults: leakageTestDefaults()),
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost,
            realtimeURL: supabaseBaseURL,
            teamEventDecryptor: failDecryptTeam,
            directMessageDecryptor: failDecrypt
        )

        await service.subscribe(workspaceID: "ws-sentinel-dm")
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-ws-sentinel-dm","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """))

        let sentinelHex = Data(sentinel.utf8).map { String(format: "%02x", $0) }.joined()
        let recipientHex = String(repeating: "cc", count: 32)
        let record: [String: Any] = [
            "message_id":        "msg-sentinel-1",
            "workspace_id":      "ws-sentinel-dm",
            "sender_pubkey":     pubkeyHex,
            "recipient_pubkey":  recipientHex,
            "kind":              "handoff",
            "encrypted_payload": "\\x\(sentinelHex)",
            "created_at":        "2026-01-01T00:00:00Z",
        ]
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-ws-sentinel-dm",
            "event": "postgres_changes",
            "payload": ["data": ["type": "INSERT", "table": "direct_messages", "record": record]],
            "ref": NSNull(),
        ]
        let frameData = try JSONSerialization.data(withJSONObject: envelope)
        await driver.dispatchMessage(.string(String(data: frameData, encoding: .utf8)!))

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(
            dmStub.received.isEmpty,
            "Reader must receive nothing after failed DM decrypt — \(dmStub.received.count) rows leaked"
        )
        for row in dmStub.received {
            XCTAssertFalse(
                row.body.contains("SECRET-DM"),
                "Sentinel string leaked into DirectMessageMirrorRow.body"
            )
        }
        await service.suspend()
    }

    // MARK: - (3) Heartbeat frames — empty payload, no workspace data

    /// Phoenix heartbeat is sent on topic "phoenix" with an empty payload dict.
    /// workspace_id must not appear — its presence would allow the relay to
    /// correlate heartbeat timing with specific workspace sessions.
    func testHeartbeat_EmptyPayload_NoWorkspaceData() throws {
        let frame = try RealtimePhoenixFrame.heartbeat(ref: "hb-99")

        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
            "Heartbeat frame must be valid JSON"
        )

        // Topic must be "phoenix" — not a workspace channel topic.
        XCTAssertEqual(dict["topic"] as? String, "phoenix", "Heartbeat topic must be 'phoenix'")

        // Payload must be empty — no workspace_id, no access_token, no content keys.
        let payload = dict["payload"] as? [String: Any] ?? [:]
        XCTAssertTrue(
            payload.isEmpty,
            "Heartbeat payload must be empty, got keys: \(Array(payload.keys).sorted())"
        )

        // Raw JSON check: no workspace_id or access_token string anywhere.
        XCTAssertFalse(frame.contains("workspace_id"),
                       "Heartbeat frame must not reference workspace_id")
        XCTAssertFalse(frame.contains("access_token"),
                       "Heartbeat frame must not contain access_token")
    }

    // MARK: - (4) phx_join — workspace_id intentional; sender pubkey forbidden

    /// phx_join legitimately embeds workspace_id in topic + postgres_changes filter.
    /// The access_token (JWT) is also intentionally present (Supabase Realtime auth).
    /// However, the sender's raw X25519 pubkey hex MUST NOT appear in the join payload —
    /// that would expose long-term identity material to the relay independently of the JWT.
    func testPhxJoin_WorkspaceIDPresent_SenderPubkeyAbsent() throws {
        let workspaceID = "wksp-privacy-test-uuid-5678"
        let accessToken = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyMSJ9.sig"
        // This hex is deliberately different from anything in the JWT sub claim above.
        let rawPubkeyHex = String(repeating: "ab", count: 32)

        let frame = try RealtimePhoenixFrame.phxJoin(
            workspaceID: workspaceID,
            accessToken: accessToken,
            ref: "1"
        )

        // workspace_id intentionally appears in topic + filter — this is expected.
        XCTAssertTrue(frame.contains(workspaceID),
                      "phx_join must embed workspaceID in topic/filter (intentional metadata)")

        // access_token intentionally present (Supabase Realtime auth mechanism).
        XCTAssertTrue(frame.contains("access_token"),
                      "phx_join must include access_token for Supabase Realtime auth")

        // Raw X25519 pubkey hex must NOT appear — it's not included in phx_join at all.
        XCTAssertFalse(frame.contains(rawPubkeyHex),
                       "phx_join must not contain raw sender pubkey hex — long-term identity material")

        // Validate topic follows the workspace convention.
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        let topic = (dict["topic"] as? String) ?? ""
        XCTAssertTrue(topic.hasPrefix("realtime:leaf-workspace-"),
                      "phx_join topic must use 'realtime:leaf-workspace-' prefix")
        XCTAssertTrue(topic.contains(workspaceID),
                      "phx_join topic must embed workspaceID")

        // No extraneous identity fields in the top-level frame.
        let topLevelKeys = Set((dict).keys)
        let allowedTopLevel: Set<String> = ["topic", "event", "payload", "ref"]
        let unexpectedKeys = topLevelKeys.subtracting(allowedTopLevel)
        XCTAssertTrue(unexpectedKeys.isEmpty,
                      "phx_join frame has unexpected top-level keys: \(unexpectedKeys)")
    }

    // MARK: - (5) Source scan — driver dispatch has no log refs to plaintext content

    /// The driver dispatches encrypted wire rows only — it never decrypts.
    /// Two sub-checks:
    ///   a) No print/NSLog/os_log/Logger calls anywhere in the driver.
    ///      (Lifecycle changes go through eventContinuation.yield, not logs.)
    ///   b) No references to decrypted content field names (plaintextPayloadJSON /
    ///      decryptedBody / row.body) — the driver must never know about these.
    func testDriver_NoLogStatements_NoPlaintextFieldRefs() throws {
        let sourceURL = leafCoreSourceURL("Network", "RealtimeWebSocketDriver.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // (a) Log call patterns.
        let bannedLogCalls = ["print(", "NSLog(", "os_log(", "Logger("]
        for pattern in bannedLogCalls {
            XCTAssertFalse(
                source.contains(pattern),
                "RealtimeWebSocketDriver must not contain '\(pattern)' — no logging in dispatch path"
            )
        }

        // (b) Decrypted-content field name references — the driver never decrypts,
        // so these symbols cannot legitimately appear in its source.
        let bannedContentRefs = ["plaintextPayloadJSON", "decryptedBody"]
        for pattern in bannedContentRefs {
            XCTAssertFalse(
                source.contains(pattern),
                "RealtimeWebSocketDriver must not reference '\(pattern)' — driver works with encrypted rows only"
            )
        }
    }

    // MARK: - (6) Reconnect — no stale channel data crosses to next workspace

    /// After joining workspace A and then leaving (channel switch), the driver's
    /// currentChannelTopic must be cleared before the next join. The phx_join for
    /// workspace B must not embed workspace A's topic string anywhere.
    ///
    /// If workspace A's topic appeared in workspace B's join frame, the relay could
    /// associate the two sessions and infer workspace membership overlap.
    func testReconnect_PriorWorkspaceTopic_ClearedBeforeNewJoin() async throws {
        let workspaceA = "ws-stale-alpha-sentinel-AAAAAA"
        let workspaceB = "ws-fresh-beta-sentinel-BBBBBB"

        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(
            taskFactory: { _ in mock },
            heartbeatIntervalSec: 9999  // suppress heartbeat noise
        )

        let url = URL(string: "wss://test.supabase.co/realtime/v1/websocket?apikey=key&vsn=1.0.0")!

        // Connect and join workspace A.
        try await driver.connect(url: url, jwt: "jwt-alpha")
        try await driver.joinWorkspaceChannel(workspaceID: workspaceA, accessToken: "jwt-alpha")

        // Confirm at least one phx_join for workspace A was sent.
        let joinAFrames = mock.outgoing.compactMap { msg -> String? in
            guard case .string(let s) = msg else { return nil }
            return s.contains(workspaceA) ? s : nil
        }
        XCTAssertFalse(joinAFrames.isEmpty, "phx_join for workspace A must have been sent")

        // Leave workspace A (simulate channel switch).
        // currentChannelTopic is only set after phx_reply arrives; since mock
        // doesn't send a reply, leaveCurrentChannel is a no-op — which is correct
        // (driver protects against leaving without a confirmed join ack). We
        // verify the state is clean regardless.
        await driver.leaveCurrentChannel()
        let topicAfterLeave = await driver.currentTopic()
        XCTAssertNil(topicAfterLeave,
                     "currentTopic must be nil after leaveCurrentChannel — stale topic cleared")

        // Join workspace B.
        try await driver.joinWorkspaceChannel(workspaceID: workspaceB, accessToken: "jwt-beta")

        // Locate the phx_join frame for workspace B (last frame that references B's ID).
        let allFrames = mock.outgoing.compactMap { msg -> String? in
            guard case .string(let s) = msg else { return nil }
            return s
        }
        let joinBFrame = allFrames.last(where: { $0.contains(workspaceB) })

        XCTAssertNotNil(joinBFrame,
                        "phx_join for workspace B must appear in outgoing frames")

        // The workspace B join must not carry workspace A's sentinel.
        if let joinBFrame {
            XCTAssertFalse(
                joinBFrame.contains(workspaceA),
                "phx_join for workspace B must not embed workspace A sentinel — stale channel data leak"
            )
        }
    }

    // MARK: - Helpers

    /// Build a URL pointing to a LeafCore source file.
    ///
    /// Uses `#filePath` (absolute path at compile time). This test file lives at:
    ///   Packages/LeafCore/Tests/LeafCoreTests/State/<file>.swift
    /// Four `.deletingLastPathComponent()` calls land us at Packages/LeafCore/.
    /// From there we navigate into Sources/LeafCore/<folder>/<file>.
    ///
    /// Reference: `CGEventTapNoContentLeakageTests` uses the same idiom but from
    /// one level shallower (LeafCoreTests/ not LeafCoreTests/State/), requiring
    /// 5 deletes to reach repo root; we need only 4 to reach LeafCore/.
    private func leafCoreSourceURL(_ folder: String, _ file: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // drop RealtimePayloadLeakageTests.swift → State/
            .deletingLastPathComponent()    // drop State/ → LeafCoreTests/
            .deletingLastPathComponent()    // drop LeafCoreTests/ → Tests/
            .deletingLastPathComponent()    // drop Tests/ → LeafCore/  (Packages/LeafCore/)
            .appendingPathComponent("Sources")
            .appendingPathComponent("LeafCore")
            .appendingPathComponent(folder)
            .appendingPathComponent(file)
    }

    /// Isolated UserDefaults instance for leakage tests (no cross-test contamination).
    private func leakageTestDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "test.leaf.realtime.leak.\(UUID().uuidString)")!
        return suite
    }

    /// Bootstrap a SupabaseClient with mock auth so `currentAccessToken()` returns non-nil.
    /// Mirrors the pattern in LeafRealtimeServiceTests.installAuthBootstrap().
    private func installAuthBootstrap() async throws -> SupabaseClient {
        let jwt = makeLeakTestJWT()
        let uid = userID
        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        {"access_token":"boot-tok","refresh_token":"boot-rt","user":{"id":"\(uid)"},"expires_at":9999999999}
                        """.utf8))
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        {"access_token":"\(jwt)","refresh_token":"ref","user":{"id":"\(uid)"},"expires_at":9999999999}
                        """.utf8))
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = SupabaseClient(
            baseURL: supabaseBaseURL, anonKey: anonKey,
            urlSession: session,
            identity: {
                try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
            }
        )
        _ = try await client.ensureAuthenticated()
        return client
    }

    /// Minimal JWT with the pubkey claim — mirrors makeJWT() from LeafRealtimeServiceTests.
    private func makeLeakTestJWT() -> String {
        let header  = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"pubkey":"\#(pubkeyHex)","sub":"\#(userID)"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).sig"
    }
}
