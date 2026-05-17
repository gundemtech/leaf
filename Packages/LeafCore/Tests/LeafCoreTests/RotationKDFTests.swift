// Phase 5.3.B — RotationKDF protocol surface tests (public).
// Verify Unimplemented placeholder discipline (mirror InviteKDF 5.2.A pattern).
// Real HKDF impl tests живут в LeafCorePrivate `ProdRotationKDFTests` (gitignored moat).

import CryptoKit
import XCTest

@testable import LeafCore

final class RotationKDFTests: XCTestCase {

    func testUnimplementedRotationKDF_Throws() {
        let dummySecret = makeDummySharedSecret()
        let newKeyID = Data(repeating: 0xAB, count: 16)
        let kdf = UnimplementedRotationKDF()

        XCTAssertThrowsError(try kdf.deriveWrapKey(sharedSecret: dummySecret, newKeyID: newKeyID)) { error in
            guard let leafError = error as? LeafError else {
                XCTFail("Expected LeafError, got \(error)")
                return
            }
            switch leafError {
            case .notImplemented: break
            default: XCTFail("Expected .notImplemented, got \(leafError)")
            }
        }
    }

    func testRotationKDFProtocol_ExistentialAccept() {
        let kdf: any RotationKDF = UnimplementedRotationKDF()
        XCTAssertNotNil(kdf as Any)
    }

    private func makeDummySharedSecret() -> SharedSecret {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        // Test fixture; both keys constructed in-line, ECDH cannot fail.
        // swiftlint:disable:next force_try
        return try! alice.sharedSecretFromKeyAgreement(with: bob.publicKey)
    }
}
