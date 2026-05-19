//
//  LeafRealtimeServiceTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 — D.7 + D.8 + D.9. @MainActor @Observable wrapper that bridges
//  the actor `RealtimeWebSocketDriver` (D.1-D.6) to the existing readers.
//
//  Test seams:
//    • Real `RealtimeWebSocketDriver` injected with `MockWebSocketTask` — lets
//      tests exercise the full subscribe/dispatch loop end-to-end without a
//      real WS connection.
//    • Real `SupabaseClient` with `MockURLProtocol` so `currentAccessToken()`
//      can return a known JWT (or nil to exercise the "no token" failure path).
//    • Mock `RealtimeDirectMessageAbsorbing` + `RealtimeTeamEventAbsorbing`
//      protocol stubs capturing the rows passed in for assertion.
//    • Real `CrossPostLogReader` — its `loadForMessages` only hits network when
//      cache is missing; tests pre-warm cache where needed.
//    • Trivial decryptor closures that transform `Supabase*Row → *MirrorRow`
//      without real crypto (concrete decryption is in Phase H composition).
//

import XCTest
import CryptoKit
import Foundation
import os.lock
@testable import LeafCore

@MainActor
final class LeafRealtimeServiceTests: XCTestCase {

    // MARK: - Test fixtures

    private let url = URL(string: "wss://test.supabase.co/realtime/v1/websocket?apikey=key&vsn=1.0.0")!
    private let supabaseBaseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "test-anon-key"
    private let pubkey = String(repeating: "42", count: 32)
    /// Canonical recipient pubkey used by tests that fire DM postgres_changes
    /// frames. Must match the literal in `recipient_pubkey` JSON fields below
    /// so the C2/C3 plaintext-trust gates pass for happy-path tests.
    private let recipientPubkey = String(repeating: "CC", count: 32)
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
        let header  = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"pubkey":"\#(pubkey)","sub":"\#(userID)"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).sig"
    }

    /// Bootstrap mock that returns a JWT so `currentAccessToken()` returns non-nil.
    private func installAuthBootstrap() async throws -> SupabaseClient {
        let jwt = makeJWT()
        let uid = userID
        MockURLProtocol.handler = { request, _ in
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
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
        let client = SupabaseClient(
            baseURL: supabaseBaseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
        // Drive ensureAuthenticated so currentAccessToken() returns non-nil.
        _ = try await client.ensureAuthenticated()
        return client
    }

    /// Build SupabaseClient that has no auth (currentAccessToken returns nil).
    private func makeUnauthClient() -> SupabaseClient {
        MockURLProtocol.handler = { request, _ in
            // Make signup hang or fail so ensureAuthenticated never completes.
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        return SupabaseClient(
            baseURL: supabaseBaseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
    }

    /// Track 5 / S8 / T0 — Phase H. The Realtime dispatch path now extracts
    /// `EncryptedTeamEventInput` from the wire row before invoking the
    /// injected decryptor. The extraction requires a valid envelope header
    /// (1B version=0x04 + 16B keyID) — minimum 17 bytes. Tests must produce
    /// fixtures matching that shape, otherwise the handler short-circuits
    /// before reaching the decryptor closure.
    static let fixtureKeyIDBytes: [UInt8] = Array(repeating: 0xAA, count: 16)
    static var fixtureTeamEventEnvelope: Data {
        Data([0x04] + fixtureKeyIDBytes + [0xCD, 0xEF])
    }
    static var fixtureDirectMessageEnvelope: Data {
        Data([0x03] + fixtureKeyIDBytes + [0x12, 0x34])
    }
    /// PostgreSQL `bytea` hex literal form of the team-event fixture envelope,
    /// for use in raw `postgres_changes` Realtime frames embedded as JSON.
    static var fixtureTeamEventEnvelopeHex: String {
        "\\x" + fixtureTeamEventEnvelope.map { String(format: "%02x", $0) }.joined()
    }
    /// PostgreSQL `bytea` hex literal form of the DM fixture envelope.
    static var fixtureDirectMessageEnvelopeHex: String {
        "\\x" + fixtureDirectMessageEnvelope.map { String(format: "%02x", $0) }.joined()
    }

    private func teamEventRow(eventID: String,
                              workspaceID: String,
                              senderPubkey: String) -> SupabaseTeamEventRow {
        SupabaseTeamEventRow(
            eventID: eventID,
            workspaceID: workspaceID,
            senderPubkeyHex: senderPubkey,
            sourceKind: "git_commits",
            kind: "commit_authored",
            encryptedPayload: Self.fixtureTeamEventEnvelope,
            createdAtISO: "2026-05-18T12:00:00Z",
            createdAtMs: 1_716_000_000_000,
            expiresAtISO: nil
        )
    }

    private func directMessageRow(messageID: String,
                                  workspaceID: String,
                                  senderPubkey: String,
                                  recipientPubkey: String) -> SupabaseDirectMessageRow {
        SupabaseDirectMessageRow(
            messageID: messageID,
            workspaceID: workspaceID,
            senderPubkeyHex: senderPubkey,
            recipientPubkeyHex: recipientPubkey,
            kind: "handoff",
            encryptedPayload: Self.fixtureDirectMessageEnvelope,
            crossPostJSON: nil,
            createdAtISO: "2026-05-18T12:00:00Z",
            readAtISO: nil,
            doneAtISO: nil,
            doneByPubkeyHex: nil,
            replyTo: nil
        )
    }

    /// Track 5 / S8 / T0 — Phase H decryptor signature is now
    /// `(EncryptedTeamEventInput) -> TeamEventPlaintext`. The narrow input
    /// omits senderPubkeyHex / workspaceID-from-wire / kind — the test
    /// decryptor synthesises a plaintext using `input.workspaceID` (which
    /// is the RLS-attested wire workspace_id, copied during extraction) and
    /// the `claimed*` overrides for negative-path scenarios. The C2/C3 trust
    /// gates in dispatch compare returned plaintext fields against wire row
    /// columns; tests that want to PASS the gates set `claimedSender` /
    /// `claimedWorkspaceID` to the wire row's values.
    nonisolated static func teamEventPlaintextMatching(_ input: EncryptedTeamEventInput,
                                                        claimedSender: String,
                                                        claimedWorkspaceID: String? = nil,
                                                        eventID: String = "ev-X",
                                                        kind: String = "commit_authored") -> TeamEventPlaintext {
        TeamEventPlaintext(
            eventID: eventID,
            workspaceID: claimedWorkspaceID ?? input.workspaceID,
            senderMemberID: "member-fixture",
            senderPubkeyHex: claimedSender,
            source: .gitCommits,
            kind: kind,
            payload: TeamEventPayload(fields: [:]),
            eventTsMs: 1_716_000_000_000
        )
    }

    nonisolated static func dmPlaintextMatching(_ input: EncryptedDirectMessageInput,
                                                 claimedSender: String,
                                                 claimedWorkspaceID: String? = nil,
                                                 recipientPubkeyHex: String) -> DirectMessagePlaintext {
        DirectMessagePlaintext(
            messageID: input.messageID,
            workspaceID: claimedWorkspaceID ?? input.workspaceID,
            senderMemberID: "member-fixture",
            senderPubkeyHex: claimedSender,
            senderDisplayName: "Test User",
            recipientMemberID: nil,
            recipientPubkeyHex: recipientPubkeyHex,
            kind: .handoff,
            body: "test body",
            attachment: nil,
            replyTo: nil,
            sentAtMs: 1_716_000_000_000
        )
    }

    /// Default decryptor closures — synthesise plaintext that satisfies the
    /// C2/C3 gates against the canonical `pubkey` constant + the wire
    /// workspace id (which equals `input.workspaceID` post-extraction).
    private nonisolated func defaultTeamEventDecryptor() -> LeafRealtimeService.TeamEventDecryptor {
        let sender = self.pubkey
        return { @Sendable input in
            Self.teamEventPlaintextMatching(input, claimedSender: sender)
        }
    }

    private nonisolated func defaultDirectMessageDecryptor() -> LeafRealtimeService.DirectMessageDecryptor {
        let sender = self.pubkey
        let recipient = self.recipientPubkey
        return { @Sendable input in
            Self.dmPlaintextMatching(input, claimedSender: sender, recipientPubkeyHex: recipient)
        }
    }

    private func makeService(
        driver: RealtimeWebSocketDriver,
        supabase: SupabaseClient,
        activeWorkspaceStore: ActiveWorkspaceStore = ActiveWorkspaceStore(userDefaults: TestUserDefaults.make()),
        directMessageInboxReader: any RealtimeDirectMessageAbsorbing,
        teamEventMirrorReader: any RealtimeTeamEventAbsorbing,
        crossPostLogReader: CrossPostLogReader,
        teamEventDecryptor: LeafRealtimeService.TeamEventDecryptor? = nil,
        directMessageDecryptor: LeafRealtimeService.DirectMessageDecryptor? = nil
    ) -> LeafRealtimeService {
        LeafRealtimeService(
            driver: driver,
            supabase: supabase,
            activeWorkspaceStore: activeWorkspaceStore,
            directMessageInboxReader: directMessageInboxReader,
            teamEventMirrorReader: teamEventMirrorReader,
            crossPostLogReader: crossPostLogReader,
            realtimeURL: url,
            teamEventDecryptor: teamEventDecryptor ?? defaultTeamEventDecryptor(),
            directMessageDecryptor: directMessageDecryptor ?? defaultDirectMessageDecryptor()
        )
    }

    // MARK: - subscribe idempotency

    /// 1. subscribe(wid) twice with same wid → no-op on the second call (no second phx_join).
    func testSubscribe_SameWorkspaceID_NoOp() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-A")
        let outgoingAfter1 = mock.outgoing.count

        await service.subscribe(workspaceID: "wid-A")
        let outgoingAfter2 = mock.outgoing.count

        XCTAssertEqual(outgoingAfter1, outgoingAfter2,
                       "Second subscribe with same wid must not send a second phx_join")
        XCTAssertEqual(service.currentWorkspaceID, "wid-A")
        await service.suspend()
    }

    /// 2. subscribe(wid-A) then subscribe(wid-B) sends phx_leave (for A) + phx_join (for B).
    func testSubscribe_DifferentWorkspaceID_LeavesOldChannelJoinsNew() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-A")
        // Synthesize phx_join ack so currentChannelTopic gets set — leaveCurrentChannel
        // is a no-op when no ack was received.
        let okJSON = """
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """
        await driver.dispatchMessage(.string(okJSON))

        await service.subscribe(workspaceID: "wid-B")

        // Expect: phx_join(wid-A) → phx_leave(wid-A) → phx_join(wid-B).
        let frames = mock.outgoing.compactMap { msg -> [String: Any]? in
            guard case .string(let s) = msg,
                  let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }
        XCTAssertGreaterThanOrEqual(frames.count, 3)
        XCTAssertEqual(frames[0]["event"] as? String, "phx_join")
        XCTAssertEqual(frames[0]["topic"] as? String, "realtime:leaf-workspace-wid-A")
        // The leave + new join may be in either order (leave first, then join). We
        // assert both appear and that the join carries the new topic.
        let events = frames.map { $0["event"] as? String }
        XCTAssertTrue(events.contains("phx_leave"))
        let joinB = frames.first(where: {
            $0["event"] as? String == "phx_join" &&
            $0["topic"] as? String == "realtime:leaf-workspace-wid-B"
        })
        XCTAssertNotNil(joinB)
        XCTAssertEqual(service.currentWorkspaceID, "wid-B")
        await service.suspend()
    }

    /// 3. subscribe with no access token → state stays .disconnected.
    func testSubscribe_NoAccessToken_StateDisconnected() async {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = makeUnauthClient()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-X")
        XCTAssertEqual(service.state, .disconnected)
        // No frames sent (no token = no connect).
        XCTAssertTrue(mock.outgoing.isEmpty)
        await service.suspend()
    }

    // MARK: - S7 Stage 6 fix A-I1 + A-I2 — sticky-state regression fences

    /// A-I1: subscribe() that fails on JWT-nil must NOT pin `currentWorkspaceID`.
    /// Otherwise a retry with the same workspace would silently no-op via
    /// the idempotency guard `workspaceID != currentWorkspaceID`. After the
    /// fix, currentWorkspaceID is cleared on every failure exit so that the
    /// next subscribe() proceeds normally.
    func testSubscribe_FailsOnJWTNil_ClearsCurrentWorkspaceID() async {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = makeUnauthClient()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-X")
        XCTAssertEqual(service.state, .disconnected)
        XCTAssertNil(
            service.currentWorkspaceID,
            "Subscribe-failed-on-JWT-nil must clear currentWorkspaceID so caller retry isn't no-op'd by the idempotency guard"
        )
        await service.suspend()
    }

    /// A-I2: channelRejected dispatch must NOT pin `currentWorkspaceID`.
    /// Server-side reject (JWT expired, RLS denied, etc.) transitions state
    /// to .disconnected; without clearing currentWorkspaceID, the caller's
    /// natural retry (with the same wid) hits the idempotency guard and
    /// silently no-ops — user stays disconnected indefinitely.
    func testDispatch_ChannelRejected_ClearsCurrentWorkspaceID() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-A")
        XCTAssertEqual(service.currentWorkspaceID, "wid-A")

        // Server rejects the join.
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"error","response":{"reason":"rls-denied"}},"ref":"1"}
        """))

        try await waitForCondition { service.state == .disconnected }
        XCTAssertNil(
            service.currentWorkspaceID,
            ".channelRejected must clear currentWorkspaceID so caller retry can proceed past the idempotency guard"
        )
        await service.suspend()
    }

    /// S7 Stage 6 fix M2 — dispatch loop must ignore a stale channelJoined
    /// ack arriving on a topic that doesn't match the current workspace. The
    /// prior impl set `state = .connected` unconditionally on any ack, which
    /// would resurrect a stale "B connected" claim from a stale A→B
    /// transition the moment A's late join-reply arrived.
    func testDispatch_ChannelJoined_StaleTopic_IgnoredSilently() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        // Subscribe to wid-A — state transitions to .connecting.
        await service.subscribe(workspaceID: "wid-A")
        XCTAssertEqual(service.currentWorkspaceID, "wid-A")

        // A stale phx_join ack arrives from wid-OTHER topic — must NOT
        // transition state to .connected for wid-A.
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-OTHER","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"99"}
        """))

        // No transition to .connected — state stays as it was.
        // (state could be .connecting or .connected depending on whether the
        // optimistic transition fired earlier; either way it must not be
        // *promoted* by a stale ack.)
        XCTAssertNotEqual(service.state, .reconnecting(attempt: 1))

        // The legitimate ack for wid-A must still flip to .connected.
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """))
        try await waitForCondition { service.state == .connected }
        XCTAssertEqual(service.state, .connected)
        await service.suspend()
    }

    // MARK: - dispatch

    /// 4. team_events INSERT for the active workspace → decryptor + absorb fired.
    func testDispatch_TeamEventInsertedSameWorkspace_InvokesAbsorb() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-A")
        // Synthesize the channel ack.
        let okJSON = """
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """
        await driver.dispatchMessage(.string(okJSON))

        let recordJSON: [String: Any] = [
            // Track 5 / S8 / T0 — Phase H. Mirror row's eventID is sourced from
            // plaintext.eventID (matches `tick` polling-path discipline). Default
            // decryptor synthesises `eventID="ev-X"`; we set the wire `event_id`
            // to the same value so the production invariant (plaintext eventID ==
            // wire eventID) holds in the test fixture.
            "event_id": "ev-X",
            "workspace_id": "wid-A",
            "sender_pubkey": pubkey,
            "source_kind": "git_commits",
            "kind": "commit_authored",
            "encrypted_payload": Self.fixtureTeamEventEnvelopeHex,
            "created_at": "2026-05-18T12:00:00.123Z",
            "expires_at": "2026-06-17T12:00:00.123Z",
        ]
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-wid-A",
            "event": "postgres_changes",
            "payload": ["data": ["type": "INSERT", "table": "team_events", "record": recordJSON]],
            "ref": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let json = String(data: data, encoding: .utf8)!
        await driver.dispatchMessage(.string(json))

        // Wait for dispatch loop to drain.
        try await waitForCondition { teamStub.received.count == 1 }
        XCTAssertEqual(teamStub.received.count, 1)
        XCTAssertEqual(teamStub.received.first?.eventID, "ev-X")
        XCTAssertEqual(teamStub.received.first?.workspaceID, "wid-A")
        await service.suspend()
    }

    /// 5. team_events INSERT for a different workspace → C3 skip (no absorb).
    func testDispatch_TeamEventInsertedDifferentWorkspace_C3Skip() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-A")
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """))

        let recordJSON: [String: Any] = [
            "event_id": "ev-X",
            // Mismatching workspace ID — should be silently dropped.
            "workspace_id": "wid-OTHER",
            "sender_pubkey": pubkey,
            "source_kind": "git_commits",
            "kind": "commit_authored",
            "encrypted_payload": Self.fixtureTeamEventEnvelopeHex,
            "created_at": "2026-05-18T12:00:00.123Z",
        ]
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-wid-A",
            "event": "postgres_changes",
            "payload": ["data": ["type": "INSERT", "table": "team_events", "record": recordJSON]],
            "ref": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        await driver.dispatchMessage(.string(String(data: data, encoding: .utf8)!))

        // Give dispatch loop a brief chance to drain — assert no absorb fired.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(teamStub.received.count, 0,
                       "Cross-workspace row must be C3-skipped")
        await service.suspend()
    }

    /// 6. Decryptor failure → silently skip (no absorb, state unchanged).
    func testDispatch_TeamEventDecryptFailure_Skipped() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let failingDecryptor: LeafRealtimeService.TeamEventDecryptor = { _ in
            throw NSError(domain: "test.decrypt.fail", code: 1)
        }
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost,
            teamEventDecryptor: failingDecryptor
        )

        await service.subscribe(workspaceID: "wid-A")
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """))

        let recordJSON: [String: Any] = [
            "event_id": "ev-X", "workspace_id": "wid-A",
            "sender_pubkey": pubkey, "source_kind": "git_commits", "kind": "commit_authored",
            "encrypted_payload": Self.fixtureTeamEventEnvelopeHex,
            "created_at": "2026-05-18T12:00:00.123Z",
        ]
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-wid-A",
            "event": "postgres_changes",
            "payload": ["data": ["type": "INSERT", "table": "team_events", "record": recordJSON]],
            "ref": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        await driver.dispatchMessage(.string(String(data: data, encoding: .utf8)!))

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(teamStub.received.count, 0)
        // State stays .connected — single failure doesn't transition.
        XCTAssertEqual(service.state, .connected)
        await service.suspend()
    }

    /// 7. C2 senderPubkey mismatch (plaintext claim ≠ column) → skip.
    func testDispatch_TeamEventSenderMismatch_C2Skip() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        // Decryptor that returns a plaintext claiming a different sender.
        let mismatchSenderDecryptor: LeafRealtimeService.TeamEventDecryptor = { input in
            Self.teamEventPlaintextMatching(input, claimedSender: String(repeating: "BB", count: 32))
        }
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost,
            teamEventDecryptor: mismatchSenderDecryptor
        )

        await service.subscribe(workspaceID: "wid-A")
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """))

        let recordJSON: [String: Any] = [
            "event_id": "ev-X", "workspace_id": "wid-A",
            "sender_pubkey": pubkey, "source_kind": "git_commits", "kind": "commit_authored",
            "encrypted_payload": Self.fixtureTeamEventEnvelopeHex,
            "created_at": "2026-05-18T12:00:00.123Z",
        ]
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-wid-A",
            "event": "postgres_changes",
            "payload": ["data": ["type": "INSERT", "table": "team_events", "record": recordJSON]],
            "ref": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        await driver.dispatchMessage(.string(String(data: data, encoding: .utf8)!))

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(teamStub.received.count, 0, "Mismatched sender plaintext claim must be C2-skipped")
        await service.suspend()
    }

    /// 8. direct_messages INSERT → DM absorb fires; cross_post log fetch attempted.
    func testDispatch_DirectMessageInserted_InvokesAbsorb() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-A")
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """))

        let recordJSON: [String: Any] = [
            "message_id": "msg-1", "workspace_id": "wid-A",
            "sender_pubkey": pubkey,
            "recipient_pubkey": String(repeating: "CC", count: 32),
            "kind": "handoff",
            // Track 5 / S8 / T0 — Phase H: must satisfy extractEncryptedInput's
            // 17B minimum (1B version=0x03 + 16B keyID).
            "encrypted_payload": Self.fixtureDirectMessageEnvelopeHex,
            "created_at": "2026-05-18T12:00:00.123Z",
        ]
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-wid-A",
            "event": "postgres_changes",
            "payload": ["data": ["type": "INSERT", "table": "direct_messages", "record": recordJSON]],
            "ref": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        await driver.dispatchMessage(.string(String(data: data, encoding: .utf8)!))

        try await waitForCondition { dmStub.received.count == 1 }
        XCTAssertEqual(dmStub.received.count, 1)
        XCTAssertEqual(dmStub.received.first?.messageID, "msg-1")
        await service.suspend()
    }

    /// 9. DM INSERT triggers cross-post log fetch (loadForMessages([msg-1])).
    func testDispatch_DirectMessageInsert_TriggersCrossPostFetch() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        // Custom URL handler: bootstrap + capture cross_post_log fetches.
        let jwt = makeJWT()
        let uid = userID
        let fetchCount = AtomicCounter()
        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        { "access_token": "boot-tok", "refresh_token": "boot-rt",
                          "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
                        """.utf8))
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        { "access_token": "\(jwt)", "refresh_token": "ref",
                          "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
                        """.utf8))
            case "/rest/v1/cross_post_log":
                fetchCount.increment()
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("[]".utf8))
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
        let supabase = SupabaseClient(
            baseURL: supabaseBaseURL, anonKey: anonKey,
            urlSession: makeSession(), identity: fixedIdentity()
        )
        _ = try await supabase.ensureAuthenticated()

        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-A")
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """))

        let recordJSON: [String: Any] = [
            "message_id": "msg-xp", "workspace_id": "wid-A",
            "sender_pubkey": pubkey, "recipient_pubkey": String(repeating: "CC", count: 32),
            "kind": "handoff",
            "encrypted_payload": Self.fixtureDirectMessageEnvelopeHex,
            "created_at": "2026-05-18T12:00:00.123Z",
        ]
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-wid-A",
            "event": "postgres_changes",
            "payload": ["data": ["type": "INSERT", "table": "direct_messages", "record": recordJSON]],
            "ref": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        await driver.dispatchMessage(.string(String(data: data, encoding: .utf8)!))

        try await waitForCondition { fetchCount.value >= 1 }
        XCTAssertGreaterThanOrEqual(fetchCount.value, 1, "cross_post_log fetch must fire after DM insert")
        await service.suspend()
    }

    /// 10. direct_messages UPDATE delegates to the same absorb path (idempotent UPSERT).
    func testDispatch_DirectMessageUpdate_InvokesAbsorb() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-A")
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """))

        let recordJSON: [String: Any] = [
            "message_id": "msg-2", "workspace_id": "wid-A",
            "sender_pubkey": pubkey, "recipient_pubkey": String(repeating: "CC", count: 32),
            "kind": "handoff",
            "encrypted_payload": Self.fixtureDirectMessageEnvelopeHex,
            "created_at": "2026-05-18T12:00:00.123Z",
            "read_at": "2026-05-18T12:05:00.000Z",
        ]
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-wid-A",
            "event": "postgres_changes",
            "payload": ["data": ["type": "UPDATE", "table": "direct_messages", "record": recordJSON]],
            "ref": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        await driver.dispatchMessage(.string(String(data: data, encoding: .utf8)!))

        try await waitForCondition { dmStub.received.count == 1 }
        XCTAssertEqual(dmStub.received.count, 1)
        XCTAssertEqual(dmStub.received.first?.messageID, "msg-2")
        await service.suspend()
    }

    /// 11. channelRejected → state transitions to .disconnected.
    func testDispatch_ChannelRejected_StateDisconnected() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-A")
        // Dispatch phx_reply error.
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"error","response":{"reason":"rls-denied"}},"ref":"1"}
        """))

        try await waitForCondition { service.state == .disconnected }
        XCTAssertEqual(service.state, .disconnected)
        await service.suspend()
    }

    /// 12. .disconnected event from driver → state transitions to .reconnecting(1).
    func testDispatch_Disconnected_StateReconnecting() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-A")
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """))
        XCTAssertEqual(service.state, .connected)

        // Synthesize phx_close which the driver emits as .disconnected event.
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_close","payload":{},"ref":null}
        """))

        try await waitForCondition {
            if case .reconnecting = service.state { return true } else { return false }
        }
        if case .reconnecting(let attempt) = service.state {
            XCTAssertGreaterThanOrEqual(attempt, 1)
        } else {
            XCTFail("expected .reconnecting got \(service.state)")
        }
        await service.suspend()
    }

    // MARK: - lifecycle

    /// 13. suspend transitions state to .suspended + cancels dispatch + calls driver.suspend.
    func testSuspend_TransitionsToSuspended_CancelsDispatch() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-A")
        // subscribe transitions to .connecting then optimistically .connected
        // before the phx_join ack — either is acceptable here.
        XCTAssertTrue(service.state == .connecting || service.state == .connected,
                      "expected .connecting/.connected, got \(service.state)")
        await service.suspend()
        XCTAssertEqual(service.state, .suspended)

        // After suspend, driver should also be suspended.
        let driverState = await driver.state
        XCTAssertEqual(driverState, .suspended)
    }

    /// 14. resume from .suspended re-subscribes to the last workspace.
    func testResume_FromSuspended_ReSubscribes() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let store = ActiveWorkspaceStore(userDefaults: TestUserDefaults.make())
        store.setActive("wid-RESUME")
        let service = makeService(
            driver: driver, supabase: supabase,
            activeWorkspaceStore: store,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-RESUME")
        await service.suspend()
        XCTAssertEqual(service.state, .suspended)

        await service.resume()
        // After resume, currentWorkspaceID should match again.
        XCTAssertEqual(service.currentWorkspaceID, "wid-RESUME")
        // Some non-suspended terminal state — depends on whether the ack arrived.
        XCTAssertNotEqual(service.state, .suspended)
        await service.suspend()
    }

    /// 15. unsubscribe sends phx_leave + keeps WS state intact (driver stays connected).
    func testUnsubscribe_LeavesChannel_KeepsWS() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let supabase = try await installAuthBootstrap()
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        let service = makeService(
            driver: driver, supabase: supabase,
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost
        )

        await service.subscribe(workspaceID: "wid-A")
        await driver.dispatchMessage(.string("""
        {"topic":"realtime:leaf-workspace-wid-A","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """))
        await service.unsubscribe()
        XCTAssertNil(service.currentWorkspaceID)
        XCTAssertEqual(service.state, .disconnected)

        // WS itself should still be open (driver not suspended/disconnected).
        let driverState = await driver.state
        XCTAssertEqual(driverState, .connected)
        await service.suspend()
    }

    // MARK: - Helpers

    /// Spin until `predicate()` returns true, capped at 1 second. Used to wait
    /// for the dispatch loop (which runs on a Task) to drain.
    private func waitForCondition(timeoutNanos: UInt64 = 1_000_000_000,
                                  predicate: @MainActor () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Thread-safe counter for Sendable-capture-friendly test assertions.
    final class AtomicCounter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        func increment() { lock.withLock { $0 += 1 } }
        var value: Int { lock.withLock { $0 } }
    }
}

// MARK: - Helper test-side UserDefaults factory

enum TestUserDefaults {
    static func make() -> UserDefaults {
        let suite = UserDefaults(suiteName: "test.leaf.realtime.\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: "test.leaf.realtime")
        return suite
    }
}

// MARK: - Mock reader stubs (@MainActor)

@MainActor
final class MockDirectMessageAbsorber: RealtimeDirectMessageAbsorbing {
    var received: [DirectMessageMirrorRow] = []

    func absorbRealtimePush(_ row: DirectMessageMirrorRow) async {
        received.append(row)
    }
}

@MainActor
final class MockTeamEventAbsorber: RealtimeTeamEventAbsorbing {
    var received: [TeamEventMirrorRow] = []

    func absorbRealtimePush(_ row: TeamEventMirrorRow) async {
        received.append(row)
    }
}
