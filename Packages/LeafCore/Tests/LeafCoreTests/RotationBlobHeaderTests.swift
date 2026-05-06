import XCTest
@testable import LeafCore

final class RotationBlobHeaderTests: XCTestCase {

    private func makeFullPrefix(version: UInt8 = RotationBlobHeader.currentVersion,
                                priorKeyID: Data = Data(repeating: 0xAA, count: 16),
                                newKeyID: Data = Data(repeating: 0xBB, count: 16),
                                recipientPubkey: Data = Data(repeating: 0xCC, count: 32)) -> Data {
        var bytes = Data()
        bytes.append(version)
        bytes.append(priorKeyID)
        bytes.append(newKeyID)
        bytes.append(recipientPubkey)
        return bytes
    }

    func testPeek_RoundTripsAllSlices() throws {
        let priorID = Data(repeating: 0x11, count: 16)
        let newID = Data(repeating: 0x22, count: 16)
        let recipient = Data(repeating: 0x33, count: 32)

        var bytes = makeFullPrefix(priorKeyID: priorID, newKeyID: newID, recipientPubkey: recipient)
        bytes.append(Data(repeating: 0xFF, count: 40)) // tail (nonce + ct + tag substitute)

        let blob = RotationBlob(bytes: bytes)
        let header = try RotationBlobHeader.peek(from: blob)

        XCTAssertEqual(header.version, RotationBlobHeader.currentVersion)
        XCTAssertEqual(header.priorKeyID, priorID)
        XCTAssertEqual(header.newKeyID, newID)
        XCTAssertEqual(header.recipientPubkey, recipient)
    }

    func testPeek_RejectShortBytes() {
        let blob = RotationBlob(bytes: Data(repeating: 0x03, count: 64)) // < 65
        XCTAssertThrowsError(try RotationBlobHeader.peek(from: blob)) { error in
            guard let leafErr = error as? LeafError, case .rotationBlobMalformed = leafErr else {
                XCTFail("expected .rotationBlobMalformed, got \(error)")
                return
            }
        }
    }

    func testPeek_RejectsUnknownVersions() {
        // 0x01 envelope, 0x02 invite, 0xFF arbitrary, 0x04 future-reserved — all rejected.
        for badVersion in [UInt8(0x01), 0x02, 0x04, 0xFF] {
            let bytes = makeFullPrefix(version: badVersion)
            let blob = RotationBlob(bytes: bytes)
            XCTAssertThrowsError(try RotationBlobHeader.peek(from: blob),
                                 "version=\(String(badVersion, radix: 16)) must reject") { error in
                guard let leafErr = error as? LeafError, case .rotationBlobMalformed = leafErr else {
                    XCTFail("expected .rotationBlobMalformed for version=\(badVersion), got \(error)")
                    return
                }
            }
        }
    }

    func testConstants_MatchSpec() {
        XCTAssertEqual(RotationBlobHeader.currentVersion, 3)
        XCTAssertEqual(RotationBlobHeader.priorKeyIDSize, 16)
        XCTAssertEqual(RotationBlobHeader.newKeyIDSize, 16)
        XCTAssertEqual(RotationBlobHeader.recipientPubkeySize, 32)
        XCTAssertEqual(RotationBlobHeader.prefixSize, 65)
        XCTAssertEqual(RotationBlobHeader.nonceSize, 12)
        XCTAssertEqual(RotationBlobHeader.tagSize, 16)
        XCTAssertEqual(RotationBlobHeader.aadPrefixSize, 77)
        XCTAssertEqual(RotationBlobHeader.fixedOverhead, 93)
    }
}
