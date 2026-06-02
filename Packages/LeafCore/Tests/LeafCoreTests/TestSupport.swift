import Foundation
@testable import LeafCore

extension EncryptionOptions {
    /// Deterministic 32-byte key for unit tests. `0xAA` pattern to make it easy
    /// to tell apart from real random keys in heap dumps if something goes
    /// wrong. Used everywhere a test opens the DB through the encrypted
    /// path — mimics prod, but without Keychain (works on any machine).
    static let deterministicTest = EncryptionOptions(
        keyProvider: .data(Data(repeating: 0xAA, count: 32))
    )
}
