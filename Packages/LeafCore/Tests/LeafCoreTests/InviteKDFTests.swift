// Phase 5.2.A — InviteKDF protocol surface tests (public).
// Verify Unimplemented placeholder discipline (mirror EnvelopeCodec
// `UnimplementedEnvelopeCodec` 5.1.C pattern). Real HKDF impl tests
// live in LeafCorePrivate `ProdInviteKDFTests` (gitignored moat).

import XCTest
import CryptoKit
@testable import LeafCore

final class InviteKDFTests: XCTestCase {

    // MARK: - 1. UnimplementedInviteKDF throws .notImplemented

    func testUnimplementedInviteKDF_Throws() {
        let dummySecret = makeDummySharedSecret()
        let kdf = UnimplementedInviteKDF()

        XCTAssertThrowsError(try kdf.deriveWrapKey(sharedSecret: dummySecret, otp: "123456")) { error in
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

    // MARK: - 2. Existential conformance — sanity check

    func testInviteKDFProtocol_ExistentialAccept() {
        let kdf: any InviteKDF = UnimplementedInviteKDF()
        // Compile-time: `kdf` is `any InviteKDF`. Runtime — no meaningful action,
        // just a smoke check that existential erasure holds no surprises.
        XCTAssertNotNil(kdf as Any)
    }

    // MARK: - Helpers

    /// Construct a `SharedSecret` via CryptoKit ECDH (there is no other way —
    /// no public init). Used only as input for UnimplementedInviteKDF (which
    /// throws before it is used).
    private func makeDummySharedSecret() -> SharedSecret {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        return try! alice.sharedSecretFromKeyAgreement(with: bob.publicKey)
    }
}
