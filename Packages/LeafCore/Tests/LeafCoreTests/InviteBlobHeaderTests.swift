import XCTest
@testable import LeafCore

final class InviteBlobHeaderTests: XCTestCase {

    func testPeek_RoundTripsAdminPubkey() throws {
        var bytes = Data()
        bytes.append(InviteBlobHeader.currentVersion)
        let pubkey = Data(repeating: 0xAB, count: 32)
        bytes.append(pubkey)
        bytes.append(Data(repeating: 0xFF, count: 28)) // tail

        let blob = InviteBlob(bytes: bytes)
        let header = try InviteBlobHeader.peek(from: blob)

        XCTAssertEqual(header.version, InviteBlobHeader.currentVersion)
        XCTAssertEqual(header.adminPubkey, pubkey)
    }

    func testPeek_RejectShortBytes() {
        let blob = InviteBlob(bytes: Data(repeating: 0x02, count: 32)) // < 33
        XCTAssertThrowsError(try InviteBlobHeader.peek(from: blob)) { error in
            guard let leafErr = error as? LeafError, case .inviteBlobMalformed = leafErr else {
                XCTFail("expected .inviteBlobMalformed, got \(error)")
                return
            }
        }
    }

    func testPeek_RejectUnknownVersion() {
        var bytes = Data([0x01]) // wrong version (envelope, not invite)
        bytes.append(Data(repeating: 0x00, count: 64))
        let blob = InviteBlob(bytes: bytes)
        XCTAssertThrowsError(try InviteBlobHeader.peek(from: blob)) { error in
            guard let leafErr = error as? LeafError, case .inviteBlobMalformed = leafErr else {
                XCTFail("expected .inviteBlobMalformed, got \(error)")
                return
            }
        }
    }

    func testConstants_MatchSpec() {
        XCTAssertEqual(InviteBlobHeader.currentVersion, 2)
        XCTAssertEqual(InviteBlobHeader.prefixSize, 33)
        XCTAssertEqual(InviteBlobHeader.nonceSize, 12)
        XCTAssertEqual(InviteBlobHeader.tagSize, 16)
        XCTAssertEqual(InviteBlobHeader.aadPrefixSize, 45)
        XCTAssertEqual(InviteBlobHeader.fixedOverhead, 61)
    }
}
