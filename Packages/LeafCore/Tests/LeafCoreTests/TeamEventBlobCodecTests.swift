// Phase Track-5 S5 — TeamEventBlobCodec protocol + Unimplemented stub.

import XCTest
@testable import LeafCore

final class TeamEventBlobCodecTests: XCTestCase {

    private func samplePlaintext() -> TeamEventPlaintext {
        TeamEventPlaintext(
            eventID: "evt-1",
            workspaceID: "wid-1",
            senderMemberID: "mid-1",
            senderPubkeyHex: "00",
            source: .gitCommits,
            kind: "gh_commit_pushed",
            payload: TeamEventPayload(fields: [:]),
            eventTsMs: 1_000
        )
    }

    func testUnimplemented_EncodeThrowsNotImplemented() {
        let codec = UnimplementedTeamEventBlobCodec()
        let keyID = Data(repeating: 0, count: 16)
        let teamKey = Data(repeating: 0, count: 32)
        XCTAssertThrowsError(try codec.encode(samplePlaintext(), keyID: keyID, teamKey: teamKey)) { error in
            if case LeafError.notImplemented = error { /* expected */ } else {
                XCTFail("expected .notImplemented, got \(error)")
            }
        }
    }

    func testUnimplemented_DecodeThrowsNotImplemented() {
        let codec = UnimplementedTeamEventBlobCodec()
        let teamKey = Data(repeating: 0, count: 32)
        let envelopeBytes = Data(repeating: 0, count: 64)
        XCTAssertThrowsError(try codec.decode(envelopeBytes, teamKey: teamKey)) { error in
            if case LeafError.notImplemented = error { /* expected */ } else {
                XCTFail("expected .notImplemented, got \(error)")
            }
        }
    }
}
