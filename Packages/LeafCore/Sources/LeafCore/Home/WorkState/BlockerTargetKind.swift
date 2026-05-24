import Foundation

/// What kind of object is blocked. Backed by free-text DB column
/// `target_kind` in M014. `.other(raw)` fallback mirrors `BlockerKind`.
public enum BlockerTargetKind: Equatable, Hashable, Sendable {
    case linearIssue
    case githubPR
    case other(String)

    public var displayName: String {
        switch self {
        case .linearIssue:
            return "Linear"
        case .githubPR:
            return "GitHub"
        case .other(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "Unknown" }
            let humanized = trimmed.replacingOccurrences(of: "_", with: " ")
            return humanized.prefix(1).uppercased() + humanized.dropFirst()
        }
    }
}
