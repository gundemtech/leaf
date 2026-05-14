// Phase Track-5 S4 — DirectMessage value types coverage.

import XCTest
@testable import LeafCore

final class DirectMessageValueTypesTests: XCTestCase {

    // MARK: - DirectMessageKind

    func testDirectMessageKind_RawValues() {
        XCTAssertEqual(DirectMessageKind.handoff.rawValue, "handoff")
        XCTAssertEqual(DirectMessageKind.task.rawValue, "task")
        XCTAssertEqual(DirectMessageKind.ping.rawValue, "ping")
    }

    func testDirectMessageKind_InitFromRawValue() {
        XCTAssertEqual(DirectMessageKind(rawValue: "handoff"), .handoff)
        XCTAssertEqual(DirectMessageKind(rawValue: "task"), .task)
        XCTAssertEqual(DirectMessageKind(rawValue: "ping"), .ping)
        XCTAssertNil(DirectMessageKind(rawValue: "shout"))
        XCTAssertNil(DirectMessageKind(rawValue: ""))
    }

    func testDirectMessageKind_AllCases() {
        XCTAssertEqual(DirectMessageKind.allCases, [.handoff, .task, .ping])
    }

    // MARK: - DirectMessagePlaintext coding round-trip

    func testDirectMessagePlaintext_RoundTrip_Minimal() throws {
        let plaintext = DirectMessagePlaintext(
            messageID: "msg-1",
            workspaceID: "w-1",
            senderMemberID: "sm-1",
            senderPubkeyHex: "abc",
            senderDisplayName: "Anton",
            recipientMemberID: nil,
            recipientPubkeyHex: "def",
            kind: .ping,
            body: "hello",
            attachment: nil,
            replyTo: nil,
            sentAtMs: 1_700_000_000_000
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(plaintext)
        let decoded = try JSONDecoder().decode(DirectMessagePlaintext.self, from: data)

        XCTAssertEqual(decoded, plaintext)
    }

    func testDirectMessagePlaintext_RoundTrip_WithAttachment() throws {
        let plaintext = DirectMessagePlaintext(
            messageID: "msg-2",
            workspaceID: "w-1",
            senderMemberID: "sm-1",
            senderPubkeyHex: "abc",
            senderDisplayName: "Anton",
            recipientMemberID: "rm-1",
            recipientPubkeyHex: "def",
            kind: .handoff,
            body: "see PR",
            attachment: DirectMessageAttachment(
                kind: "github_pr",
                externalRef: "PR #142",
                displayLabel: "leaf-relay/142"
            ),
            replyTo: "msg-parent",
            sentAtMs: 1_700_000_000_000
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(plaintext)
        let decoded = try JSONDecoder().decode(DirectMessagePlaintext.self, from: data)

        XCTAssertEqual(decoded, plaintext)
        XCTAssertEqual(decoded.attachment?.displayLabel, "leaf-relay/142")
        XCTAssertEqual(decoded.replyTo, "msg-parent")
    }

    func testDirectMessagePlaintext_SnakeCaseWireKeys() throws {
        let plaintext = DirectMessagePlaintext(
            messageID: "msg-1",
            workspaceID: "w-1",
            senderMemberID: "sm-1",
            senderPubkeyHex: "abc",
            senderDisplayName: "Anton",
            recipientMemberID: nil,
            recipientPubkeyHex: "def",
            kind: .ping,
            body: "hi",
            attachment: nil,
            replyTo: nil,
            sentAtMs: 1_000
        )
        let data = try JSONEncoder().encode(plaintext)
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))

        for key in [
            "message_id", "workspace_id", "sender_member_id", "sender_pubkey_hex",
            "sender_display_name", "recipient_pubkey_hex", "sent_at_ms"
        ] {
            XCTAssertTrue(raw.contains("\"\(key)\""), "expected key \(key); got: \(raw)")
        }
        // Should NOT contain camelCase variants.
        for camel in ["messageId", "sentAtMs"] {
            XCTAssertFalse(raw.contains("\"\(camel)\""), "unexpected camelCase key \(camel); got: \(raw)")
        }
    }

    func testDirectMessagePlaintext_Hashable() {
        let a = DirectMessagePlaintext(
            messageID: "m1", workspaceID: "w", senderMemberID: "sm",
            senderPubkeyHex: "abc", senderDisplayName: "A",
            recipientMemberID: nil, recipientPubkeyHex: "def",
            kind: .ping, body: "h", attachment: nil, replyTo: nil, sentAtMs: 1
        )
        let b = a
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    // MARK: - SentDirectMessage

    func testSentDirectMessage_PushDispatchStatusEquatable() {
        XCTAssertEqual(
            SentDirectMessage.PushDispatchStatus.sent,
            .sent
        )
        XCTAssertEqual(
            SentDirectMessage.PushDispatchStatus.skipped,
            .skipped
        )
        XCTAssertEqual(
            SentDirectMessage.PushDispatchStatus.failed("network down"),
            .failed("network down")
        )
        XCTAssertNotEqual(
            SentDirectMessage.PushDispatchStatus.failed("a"),
            .failed("b")
        )
        XCTAssertNotEqual(
            SentDirectMessage.PushDispatchStatus.sent,
            .skipped
        )
    }

    func testSentDirectMessage_Init() {
        let s = SentDirectMessage(
            messageID: "m1", createdAtISO: "2026-05-14T10:00:00Z",
            pushDispatchStatus: .sent
        )
        XCTAssertEqual(s.messageID, "m1")
        XCTAssertEqual(s.pushDispatchStatus, .sent)
    }

    // MARK: - DirectMessageBlobCodec — Unimplemented

    func testUnimplementedCodec_EncodeThrowsNotImplemented() {
        let codec = UnimplementedDirectMessageBlobCodec()
        let plaintext = DirectMessagePlaintext(
            messageID: "m1", workspaceID: "w", senderMemberID: "sm",
            senderPubkeyHex: "abc", senderDisplayName: "A",
            recipientMemberID: nil, recipientPubkeyHex: "def",
            kind: .ping, body: "h", attachment: nil, replyTo: nil, sentAtMs: 1
        )
        let keyID = Data(repeating: 0xaa, count: 16)
        let teamKey = Data(repeating: 0xbb, count: 32)

        XCTAssertThrowsError(try codec.encode(plaintext, keyID: keyID, teamKey: teamKey)) { err in
            if case LeafError.notImplemented = err { return }
            XCTFail("expected notImplemented, got \(err)")
        }
    }

    func testUnimplementedCodec_DecodeThrowsNotImplemented() {
        let codec = UnimplementedDirectMessageBlobCodec()
        let teamKey = Data(repeating: 0xbb, count: 32)
        XCTAssertThrowsError(try codec.decode(Data(), teamKey: teamKey)) { err in
            if case LeafError.notImplemented = err { return }
            XCTFail("expected notImplemented, got \(err)")
        }
    }

    // MARK: - LeafError new cases

    func testLeafError_S4Cases_Exist() {
        // Compile-time check — exercises each case.
        let cases: [LeafError] = [
            .directMessageBlobMalformed,
            .directMessageBodyTooLarge,
            .apnsRegistrationFailed(reason: "test"),
            .supabaseSessionStoreFailure(reason: "test"),
            .apnsPushDispatchFailed(reason: "test")
        ]
        XCTAssertEqual(cases.count, 5)
    }
}
