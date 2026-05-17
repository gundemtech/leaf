// Phase 5.2.A — KeyAgreement (X25519 ECDH wrapper) tests.
// Verifies CryptoKit Curve25519 ECDH symmetry + hex decode validation
// для invitee/admin pubkey exchange (5.2.D/E callers).

import CryptoKit
import XCTest

@testable import LeafCore

final class KeyAgreementTests: XCTestCase {

    // MARK: - 1. ECDH symmetry — alice ⇆ bob

    func testSharedSecret_RoundTrip_ECDHSymmetric() throws {
        let alicePriv = Curve25519.KeyAgreement.PrivateKey()
        let bobPriv = Curve25519.KeyAgreement.PrivateKey()

        let alicePubHex = alicePriv.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        let bobPubHex = bobPriv.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()

        let aliceSide = try KeyAgreement.sharedSecret(
            privateKey: alicePriv,
            peerPublicKeyHex: bobPubHex
        )
        let bobSide = try KeyAgreement.sharedSecret(
            privateKey: bobPriv,
            peerPublicKeyHex: alicePubHex
        )

        // SharedSecret не Equatable (constant-time semantics) → compare bytes.
        let aliceBytes = aliceSide.withUnsafeBytes { Data($0) }
        let bobBytes = bobSide.withUnsafeBytes { Data($0) }
        XCTAssertEqual(aliceBytes, bobBytes)
        XCTAssertEqual(aliceBytes.count, 32)
    }

    // MARK: - 2. Bad hex → throws

    func testDecodePublicKey_BadHex_Throws() {
        let badHex = String(repeating: "Z", count: 64)  // 64 chars, non-hex.
        XCTAssertThrowsError(try KeyAgreement.decodePublicKey(hex: badHex)) { error in
            assertInvalidPayload(error)
        }
    }

    // MARK: - 3. Short hex → throws

    func testDecodePublicKey_ShortHex_Throws() {
        let shortHex = String(repeating: "ab", count: 31)  // 62 chars.
        XCTAssertThrowsError(try KeyAgreement.decodePublicKey(hex: shortHex)) { error in
            assertInvalidPayload(error)
        }
    }

    // MARK: - 4. Odd-length hex → throws

    func testDecodePublicKey_OddLength_Throws() {
        let oddHex = String(repeating: "a", count: 63)  // 63 chars.
        XCTAssertThrowsError(try KeyAgreement.decodePublicKey(hex: oddHex)) { error in
            assertInvalidPayload(error)
        }
    }

    // MARK: - 5. Lenient case — uppercase hex decodes равно lowercase

    /// Pubkeys serialize through `String(format: "%02x", _)` → always lowercase
    /// в нашем flow. Defensive: lenient decoder survives accidental uppercase
    /// (e.g., copy-paste из tool которое автоматически uppercase'ит). Test
    /// pins lenient capability, чтобы не drift'нуть в strict-lowercase
    /// silently при будущих refactor'ах.
    func testDecodePublicKey_UppercaseHex_DecodesEqualToLowercase() throws {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let lowerHex = priv.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        let upperHex = lowerHex.uppercased()

        let lower = try KeyAgreement.decodePublicKey(hex: lowerHex)
        let upper = try KeyAgreement.decodePublicKey(hex: upperHex)

        XCTAssertEqual(lower.rawRepresentation, upper.rawRepresentation)
    }

    // MARK: - Helpers

    private func assertInvalidPayload(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let leafError = error as? LeafError else {
            XCTFail("Expected LeafError, got \(error)", file: file, line: line)
            return
        }
        switch leafError {
        case .invalidPayload: break
        default: XCTFail("Expected .invalidPayload, got \(leafError)", file: file, line: line)
        }
    }
}
