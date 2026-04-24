import Foundation
@testable import LeafCore

extension EncryptionOptions {
    /// Deterministic 32-byte key для unit-тестов. `0xAA` pattern чтобы легко
    /// отличить от реальных random keys в heap dumps если что-то пойдёт
    /// не так. Используется везде где тест открывает DB через encrypted
    /// path — имитирует prod, но без Keychain (работает на любой машине).
    static let deterministicTest = EncryptionOptions(
        keyProvider: .data(Data(repeating: 0xAA, count: 32))
    )
}
