import XCTest
@testable import LeafCore

final class EnvelopeHeaderTests: XCTestCase {

    // MARK: - peek round-trip

    func testPeek_RoundTrip() throws {
        let keyID = Data((0..<16).map { UInt8($0) })
        var bytes = Data([EnvelopeHeader.currentVersion])
        bytes.append(keyID)
        bytes.append(Data(repeating: 0xAA, count: 32))   // arbitrary trailing bytes

        let header = try EnvelopeHeader.peek(from: bytes)

        XCTAssertEqual(header.version, EnvelopeHeader.currentVersion)
        XCTAssertEqual(header.keyID, keyID)
    }

    // MARK: - peek rejects short bytes

    func testPeek_RejectShortBytes() {
        for size in 0..<17 {
            let bytes = Data(repeating: 0x01, count: size)
            XCTAssertThrowsError(try EnvelopeHeader.peek(from: bytes),
                                 "size=\(size) must throw") { error in
                XCTAssertTrue(isCorruptedEnvelope(error),
                              "size=\(size) wrong error: \(error)")
            }
        }
    }

    // MARK: - peek rejects unknown version

    func testPeek_RejectUnknownVersion() {
        let keyID = Data(repeating: 0x42, count: 16)

        for version: UInt8 in [0, 2, 3, 99, 255] {
            var bytes = Data([version])
            bytes.append(keyID)
            XCTAssertThrowsError(try EnvelopeHeader.peek(from: bytes),
                                 "version=\(version) must throw") { error in
                XCTAssertTrue(isCorruptedEnvelope(error),
                              "version=\(version) wrong error: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func isCorruptedEnvelope(_ error: Error) -> Bool {
        guard let leafErr = error as? LeafError else { return false }
        if case .corruptedEnvelope = leafErr { return true }
        return false
    }
}
