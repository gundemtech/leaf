// Phase Track-5 S5 — TeamEventMirrorService static helper coverage.
// Full async tick test deferred to acceptance gate (needs workspace +
// team_keys + keystore + Supabase mock scaffolding); covered here are the
// keyID-bytes → UUID-string round-trip and payload JSON serialization helpers
// that the loop depends on for correctness.

import XCTest
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
}
