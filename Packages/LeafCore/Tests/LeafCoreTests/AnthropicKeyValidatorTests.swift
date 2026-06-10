import Testing

@testable import LeafCore

@Suite("AnthropicKeyValidator")
struct AnthropicKeyValidatorTests {
  @Test func emptyAndWhitespaceRejected() {
    #expect(AnthropicKeyValidator.validate("") == .emptyInput)
    #expect(AnthropicKeyValidator.validate("  \n\t") == .emptyInput)
  }

  @Test func skAntPrefixIsOk() {
    #expect(
      AnthropicKeyValidator.validate("  sk-ant-api03-abc123  ")
        == .ok("sk-ant-api03-abc123"))
  }

  @Test func otherFormatsAreSuspiciousButCarryTrimmedKey() {
    #expect(
      AnthropicKeyValidator.validate(" some-other-token ")
        == .suspiciousFormat("some-other-token"))
  }
}
