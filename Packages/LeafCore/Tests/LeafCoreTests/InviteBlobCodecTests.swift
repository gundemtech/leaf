import CryptoKit
import XCTest

@testable import LeafCore

final class InviteBlobCodecTests: XCTestCase {

    private let codec = UnimplementedInviteBlobCodec()

    private func makePlaintext() -> InvitePlaintext {
        InvitePlaintext(
            teamKeyBase64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            teamKeyID: "11111111-2222-3333-4444-555555555555",
            orgID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            orgName: "Leaf",
            adminMemberID: "99999999-8888-7777-6666-555555555555",
            adminDisplayName: "Alex",
            issuedAtMs: 1_730_000_000_000
        )
    }

    func testUnimplementedCodec_EncodeThrowsNotImplemented() {
        let pubkey = Data(repeating: 0x01, count: 32)
        let key = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(
            try codec.encode(makePlaintext(), adminPubkey: pubkey, wrapKey: key)
        ) { error in
            guard let leafErr = error as? LeafError, case .notImplemented = leafErr else {
                XCTFail("expected .notImplemented, got \(error)")
                return
            }
        }
    }

    func testUnimplementedCodec_DecodeThrowsNotImplemented() {
        let blob = InviteBlob(bytes: Data(repeating: 0, count: 64))
        let key = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(
            try codec.decode(blob, wrapKey: key)
        ) { error in
            guard let leafErr = error as? LeafError, case .notImplemented = leafErr else {
                XCTFail("expected .notImplemented, got \(error)")
                return
            }
        }
    }
}
