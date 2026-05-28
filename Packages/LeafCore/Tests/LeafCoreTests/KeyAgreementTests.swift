// Phase 5.2.A — KeyAgreement (X25519 ECDH wrapper) tests.
// Verifies CryptoKit Curve25519 ECDH symmetry + hex decode validation
// для invitee/admin pubkey exchange (5.2.D/E callers).

import XCTest
import CryptoKit
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

    // MARK: - 6. Low-order / small-subgroup peer point → throws .lowOrderPoint

    /// RFC 7748 §6.1 contributory-behaviour: an all-zero (u=0) peer point yields a
    /// degenerate shared secret. CryptoKit on macOS ≥ 26 rejects it at the agreement
    /// step (corecrypto −7); `sharedSecret` reclassifies that into `.lowOrderPoint`.
    func testSharedSecret_ZeroPeerPublicKey_ThrowsLowOrderPoint() {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let zeroHex = String(repeating: "00", count: 32)
        XCTAssertThrowsError(
            try KeyAgreement.sharedSecret(privateKey: priv, peerPublicKeyHex: zeroHex)
        ) { error in
            assertLowOrderPoint(error)
        }
    }

    /// A canonical Curve25519 small-order (order-8) point. Must be rejected like u=0.
    func testSharedSecret_SmallOrderPoint_ThrowsLowOrderPoint() {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let order8Hex = "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"
        XCTAssertThrowsError(
            try KeyAgreement.sharedSecret(privateKey: priv, peerPublicKeyHex: order8Hex)
        ) { error in
            assertLowOrderPoint(error)
        }
    }

    /// Regression guard: a valid peer key must still complete ECDH (no false reject).
    func testSharedSecret_ValidPeer_DoesNotThrow() throws {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let peerHex = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        let secret = try KeyAgreement.sharedSecret(privateKey: priv, peerPublicKeyHex: peerHex)
        XCTAssertEqual(secret.withUnsafeBytes { Data($0) }.count, 32)
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

    private func assertLowOrderPoint(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let leafError = error as? LeafError else {
            XCTFail("Expected LeafError, got \(error)", file: file, line: line)
            return
        }
        switch leafError {
        case .lowOrderPoint: break
        default: XCTFail("Expected .lowOrderPoint, got \(leafError)", file: file, line: line)
        }
    }
}
