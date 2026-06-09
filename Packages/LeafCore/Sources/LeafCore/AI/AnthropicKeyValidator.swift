import Foundation

/// AI-UI-1 — pure pre-save validation for the Settings BYOK key field.
/// `suspiciousFormat` is a WARNING, not a blocker — Anthropic key formats may
/// change; the caller may still save the trimmed value. Never logs the input.
public enum AnthropicKeyValidator {
  public enum Verdict: Equatable, Sendable {
    case ok(String)
    case emptyInput
    case suspiciousFormat(String)
  }

  public static func validate(_ raw: String) -> Verdict {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return .emptyInput }
    return key.hasPrefix("sk-ant-") ? .ok(key) : .suspiciousFormat(key)
  }
}
