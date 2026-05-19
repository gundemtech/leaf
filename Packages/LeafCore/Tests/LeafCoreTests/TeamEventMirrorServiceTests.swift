// Phase Track-5 S5 — TeamEventMirrorService static helper coverage.
// Track 5 / S8 / T0 — Phase H decryptOnly(_:) coverage.

import XCTest
import CryptoKit
@testable import LeafCore

final class TeamEventMirrorServiceTests: XCTestCase {

    func testKeyIDDataToUUIDString_RoundTrip() {
        let uuid = UUID()
        let bytes = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        let back = TeamEventMirrorService.keyIDDataToUUIDString(bytes)
        XCTAssertEqual(back, uuid.uuidString.lowercased())
    }

    func testKeyIDDataToUUIDString_WrongLength_ReturnsEmpty() {
        XCTAssertEqual(TeamEventMirrorService.keyIDDataToUUIDString(Data(repeating: 0, count: 8)), "")
        XCTAssertEqual(TeamEventMirrorService.keyIDDataToUUIDString(Data()), "")
    }

    func testPayloadJSONString_DeterministicEncodingWithSortedKeys() throws {
        let payload = TeamEventPayload(fields: [
            "b_key": "two",
            "a_key": "one",
            "c_key": "three"
        ])
        let s1 = try TeamEventMirrorService.payloadJSONString(payload)
        let s2 = try TeamEventMirrorService.payloadJSONString(payload)
        XCTAssertEqual(s1, s2)
        // Keys appear in alphabetical order under .sortedKeys.
        XCTAssertNotNil(s1.range(of: "\"a_key\":\"one\""))
        XCTAssertLessThan(s1.range(of: "\"a_key\"")!.lowerBound, s1.range(of: "\"b_key\"")!.lowerBound)
    }

    func testEnvelopeVersionConstantPinnedTo0x04() {
        XCTAssertEqual(TeamEventMirrorService.teamEventEnvelopeVersion, 0x04)
    }

    func testEnvelopeHeaderSizeConstantPinnedTo17() {
        XCTAssertEqual(TeamEventMirrorService.envelopeHeaderSize, 17)
    }

    // MARK: - Track 5 / S8 / T0 — decryptOnly(_:) coverage

    func testDecryptOnly_ValidEnvelope_ReturnsPlaintext() async throws {
        let h = try TestHarness.make()
        defer { try? FileManager.default.removeItem(at: h.tempDir) }

        let plaintext = TeamEventPlaintext(
            eventID: "evt-1",
            workspaceID: h.workspaceID,
            senderMemberID: "mid-1",
            senderPubkeyHex: "00",
            source: .gitCommits,
            kind: "gh_commit_pushed",
            payload: TeamEventPayload(fields: ["k": "v"]),
            eventTsMs: 1_000
        )

        let codec = TestTeamEventCodec()
        let keyIDBytes = h.keyIDBytes
        let envelope = try codec.encode(plaintext, keyID: keyIDBytes, teamKey: h.teamKeyBytes)
        let svc = TeamEventMirrorService(
            database: h.db,
            supabase: h.supabase,
            codec: codec,
            keystoreRoot: h.keystoreRoot
        )

        let input = EncryptedTeamEventInput(
            workspaceID: h.workspaceID,
            encryptedPayload: envelope,
            keyID: h.keyIDUUID,
            aadHeader: envelope.prefix(17)
        )

        let decoded = try await svc.decryptOnly(input)
        XCTAssertEqual(decoded.eventID, "evt-1")
        XCTAssertEqual(decoded.workspaceID, h.workspaceID)
        XCTAssertEqual(decoded.kind, "gh_commit_pushed")
        XCTAssertEqual(decoded.source, .gitCommits)
    }

    func testDecryptOnly_KeyNotInKeystore_Throws() async throws {
        let h = try TestHarness.make()
        defer { try? FileManager.default.removeItem(at: h.tempDir) }

        let codec = TestTeamEventCodec()
        let svc = TeamEventMirrorService(
            database: h.db,
            supabase: h.supabase,
            codec: codec,
            keystoreRoot: h.keystoreRoot
        )

        // Unknown keyID — keystore has no .key file for this UUID.
        let unknownKeyID = UUID()
        let input = EncryptedTeamEventInput(
            workspaceID: h.workspaceID,
            encryptedPayload: Data(repeating: 0, count: 64),
            keyID: unknownKeyID,
            aadHeader: Data(repeating: 0, count: 17)
        )

        do {
            _ = try await svc.decryptOnly(input)
            XCTFail("expected throw")
        } catch {
            // any throw is acceptable — keystore returns LeafError.keyFileUnavailable
            // when the file is absent; surface to caller.
        }
    }

    func testDecryptOnly_WrongTeamKey_DecryptError() async throws {
        let h = try TestHarness.make()
        defer { try? FileManager.default.removeItem(at: h.tempDir) }

        // Encrypt under one key, but seed the keystore with a different key
        // bytes under the same keyID — codec.decode must reject.
        let plaintext = TeamEventPlaintext(
            eventID: "evt-1",
            workspaceID: h.workspaceID,
            senderMemberID: "mid-1",
            senderPubkeyHex: "00",
            source: .gitCommits,
            kind: "gh_commit_pushed",
            payload: TeamEventPayload(fields: [:]),
            eventTsMs: 1_000
        )

        let encodeKey = Data(repeating: 0xAA, count: 32)
        let storeKey = Data(repeating: 0xBB, count: 32)  // mismatched

        // Re-write the keystore entry with the bad key bytes.
        try TeamKeystore.writeTeamKey(storeKey,
                                       workspaceID: h.workspaceID,
                                       keyID: h.keyIDStr,
                                       at: h.keystoreRoot)

        let codec = TestTeamEventCodec()
        let envelope = try codec.encode(plaintext, keyID: h.keyIDBytes, teamKey: encodeKey)
        let svc = TeamEventMirrorService(
            database: h.db,
            supabase: h.supabase,
            codec: codec,
            keystoreRoot: h.keystoreRoot
        )

        let input = EncryptedTeamEventInput(
            workspaceID: h.workspaceID,
            encryptedPayload: envelope,
            keyID: h.keyIDUUID,
            aadHeader: envelope.prefix(17)
        )

        do {
            _ = try await svc.decryptOnly(input)
            XCTFail("expected throw — TestTeamEventCodec validates key bytes match")
        } catch {
            // codec.decode throws LeafError.teamEventBlobMalformed on tag mismatch
            // (or equivalent on key mismatch in the test codec).
        }
    }
}

// MARK: - Test fixtures

/// Lightweight test codec mirroring the byte layout of the real prod codec
/// (version + keyID + nonce + JSON body + tag) but without AES-GCM.
/// Validates teamKey by encoding the SHA-256 of the key into the "nonce"
/// slot and rejecting on mismatch in decode.
private struct TestTeamEventCodec: TeamEventBlobCodec {
    func encode(_ plaintext: TeamEventPlaintext, keyID: Data, teamKey: Data) throws -> Data {
        var bytes = Data()
        bytes.append(0x04)
        bytes.append(keyID)
        // Nonce slot — bind to teamKey hash so wrong-key decode fails deterministically.
        let keyHash = SHA256.hash(data: teamKey)
        bytes.append(Data(keyHash.prefix(12)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(plaintext)
        bytes.append(json)
        bytes.append(Data(repeating: 0, count: 16))  // tag slot
        return bytes
    }

    func decode(_ bytes: Data, teamKey: Data) throws -> TeamEventPlaintext {
        guard bytes.count > 29 + 16 else { throw LeafError.teamEventBlobMalformed }
        guard bytes[bytes.startIndex] == 0x04 else { throw LeafError.teamEventBlobMalformed }
        // Verify nonce slot matches SHA-256(teamKey).prefix(12) — proxy for AES-GCM tag.
        let nonceStart = bytes.index(bytes.startIndex, offsetBy: 17)
        let nonceEnd = bytes.index(nonceStart, offsetBy: 12)
        let nonceSlice = Data(bytes[nonceStart..<nonceEnd])
        let keyHash = SHA256.hash(data: teamKey)
        guard nonceSlice == Data(keyHash.prefix(12)) else {
            throw LeafError.teamEventBlobMalformed
        }
        let start = bytes.index(bytes.startIndex, offsetBy: 29)
        let end = bytes.index(bytes.endIndex, offsetBy: -16)
        return try JSONDecoder().decode(TeamEventPlaintext.self, from: Data(bytes[start..<end]))
    }
}

private struct TestHarness {
    let tempDir: URL
    let db: LeafCore.Database
    let supabase: SupabaseClient
    let workspaceID: String
    let keyIDStr: String
    let keyIDUUID: UUID
    let keyIDBytes: Data
    let teamKeyBytes: Data
    let keystoreRoot: URL

    static func make() throws -> TestHarness {
        let workspaceID = UUID().uuidString.lowercased()
        let keyIDUUID = UUID()
        let keyIDStr = keyIDUUID.uuidString.lowercased()
        let keyIDBytes = withUnsafeBytes(of: keyIDUUID.uuid) { Data($0) }
        let teamKey = Data(repeating: 0xAA, count: 32)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-mirror-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let db = try LeafCore.Database.openForWrite(
            at: tempDir.appendingPathComponent("events.sqlite"),
            config: .weakDefaults,
            encryption: .deterministicTest
        )
        // decryptOnly(_:) does NOT validate workspace presence (unlike tick(workspaceID:)),
        // so we skip seeding `workspaces` — keystore + codec are sufficient.

        let keystoreRoot = tempDir.appendingPathComponent("keystore")
        try FileManager.default.createDirectory(at: keystoreRoot, withIntermediateDirectories: true)
        try TeamKeystore.writeTeamKey(teamKey,
                                       workspaceID: workspaceID,
                                       keyID: keyIDStr,
                                       at: keystoreRoot)

        let supabase = SupabaseClient(
            baseURL: URL(string: "https://test.supabase.co")!,
            anonKey: "k",
            urlSession: URLSession(configuration: .ephemeral),
            identity: {
                try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x02, count: 32))
            }
        )

        return TestHarness(
            tempDir: tempDir,
            db: db,
            supabase: supabase,
            workspaceID: workspaceID,
            keyIDStr: keyIDStr,
            keyIDUUID: keyIDUUID,
            keyIDBytes: keyIDBytes,
            teamKeyBytes: teamKey,
            keystoreRoot: keystoreRoot
        )
    }
}
