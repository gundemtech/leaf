//
//  EncryptedRowShapeTests.swift
//  LeafCoreTests
//
//  Track 5 / S8 / T0 — Phase H Realtime decryption wiring.
//
//  Compile-time fence (A-I4 carry-over from S7 Stage 6): the decryptor
//  closure must NOT have access to RLS-attested server fields (senderPubkeyHex
//  / kind / replyTo) BEFORE the C2/C3 trust gates apply. Enforced structurally
//  by the `EncryptedTeamEventInput` and `EncryptedDirectMessageInput` types —
//  they deliberately omit those fields. Any future refactor that adds them
//  here breaks the fence and must be re-reviewed.
//
//  This test uses Mirror reflection to assert the shape contract directly
//  on the struct field labels — survives doc-comment drift / typo refactors.
//

import XCTest
@testable import LeafCore

final class EncryptedRowShapeTests: XCTestCase {

    // MARK: - EncryptedTeamEventInput

    func testEncryptedTeamEventInput_HasOnlyAllowedFields() {
        let input = EncryptedTeamEventInput(
            workspaceID: "wid",
            encryptedPayload: Data([0x04]),
            keyID: UUID(),
            aadHeader: Data([0x04, 0x00])
        )
        let labels = Mirror(reflecting: input).children
            .compactMap { $0.label }
        let allowed: Set<String> = ["workspaceID", "encryptedPayload", "keyID", "aadHeader"]
        XCTAssertEqual(Set(labels), allowed,
            "EncryptedTeamEventInput must only contain {workspaceID, encryptedPayload, keyID, aadHeader}; found \(labels)")
    }

    func testEncryptedTeamEventInput_DoesNotContainBannedFields() {
        let input = EncryptedTeamEventInput(
            workspaceID: "wid",
            encryptedPayload: Data([0x04]),
            keyID: UUID(),
            aadHeader: Data([0x04, 0x00])
        )
        let labels = Set(Mirror(reflecting: input).children.compactMap { $0.label })
        // The decryptor MUST NOT see these BEFORE C2/C3 gates apply.
        let banned: [String] = ["senderPubkeyHex", "kind", "replyTo"]
        for field in banned {
            XCTAssertFalse(labels.contains(field),
                "EncryptedTeamEventInput must NOT contain '\(field)' — compile-time fence (A-I4)")
        }
    }

    // MARK: - EncryptedDirectMessageInput

    func testEncryptedDirectMessageInput_HasOnlyAllowedFields() {
        let input = EncryptedDirectMessageInput(
            workspaceID: "wid",
            messageID: "mid",
            encryptedPayload: Data([0x03]),
            keyID: UUID(),
            aadHeader: Data([0x03, 0x00])
        )
        let labels = Mirror(reflecting: input).children
            .compactMap { $0.label }
        let allowed: Set<String> = ["workspaceID", "messageID", "encryptedPayload", "keyID", "aadHeader"]
        XCTAssertEqual(Set(labels), allowed,
            "EncryptedDirectMessageInput must only contain {workspaceID, messageID, encryptedPayload, keyID, aadHeader}; found \(labels)")
    }

    func testEncryptedDirectMessageInput_DoesNotContainBannedFields() {
        let input = EncryptedDirectMessageInput(
            workspaceID: "wid",
            messageID: "mid",
            encryptedPayload: Data([0x03]),
            keyID: UUID(),
            aadHeader: Data([0x03, 0x00])
        )
        let labels = Set(Mirror(reflecting: input).children.compactMap { $0.label })
        // messageID is allowed — it's a PK identifier (RLS-attested, harmless).
        // The rest are banned BEFORE C2/C3 gates apply.
        let banned: [String] = ["senderPubkeyHex", "recipientPubkeyHex", "kind", "replyTo"]
        for field in banned {
            XCTAssertFalse(labels.contains(field),
                "EncryptedDirectMessageInput must NOT contain '\(field)' — compile-time fence (A-I4)")
        }
    }

    // MARK: - Sendable conformance (compile-time assertion via passing to @Sendable closure)

    func testEncryptedRowsAreSendable() async {
        let teamInput = EncryptedTeamEventInput(
            workspaceID: "wid", encryptedPayload: Data(), keyID: UUID(), aadHeader: Data()
        )
        let dmInput = EncryptedDirectMessageInput(
            workspaceID: "wid", messageID: "mid", encryptedPayload: Data(), keyID: UUID(), aadHeader: Data()
        )
        // If either struct loses Sendable conformance, this won't compile.
        let captured: @Sendable () -> Void = { _ = teamInput; _ = dmInput }
        await Task { captured() }.value
    }
}
