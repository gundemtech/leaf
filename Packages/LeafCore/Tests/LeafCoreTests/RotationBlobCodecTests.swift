import CryptoKit
import XCTest

@testable import LeafCore

final class RotationBlobCodecTests: XCTestCase {

    private let codec = UnimplementedRotationBlobCodec()

    private func makePlaintext() -> RotationPlaintext {
        RotationPlaintext(
            kind: .rotation,
            newTeamKeyBase64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            newKeyID: "22222222-3333-4444-5555-666666666666",
            priorKeyID: "11111111-2222-3333-4444-555555555555",
            generatedAtMs: 1_730_000_000_000,
            removedMemberID: nil
        )
    }

    func testUnimplementedCodec_EncodeThrowsNotImplemented() {
        let pubkey = Data(repeating: 0x01, count: 32)
        let key = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(
            try codec.encode(makePlaintext(), recipientPubkey: pubkey, wrapKey: key)
        ) { error in
            guard let leafErr = error as? LeafError, case .notImplemented = leafErr else {
                XCTFail("expected .notImplemented, got \(error)")
                return
            }
        }
    }

    func testUnimplementedCodec_DecodeThrowsNotImplemented() {
        let blob = RotationBlob(bytes: Data(repeating: 0, count: 128))
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
