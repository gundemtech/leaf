import Foundation

/// Why a `Blocker` is blocking. Backed by free-text DB column `blocker_kind`
/// in M014 — detectors may emit new kinds without code change, so we keep an
/// `.other(String)` fallback to prevent decode crashes.
public enum BlockerKind: Equatable, Hashable, Sendable {
    case patternBlockedOn
    case linearStuck
    case other(String)

    public var displayName: String {
        switch self {
        case .patternBlockedOn:
            return "Pattern blocked on"
        case .linearStuck:
            return "Linear stuck"
        case .other(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "Unknown" }
            let humanized = trimmed.replacingOccurrences(of: "_", with: " ")
            return humanized.prefix(1).uppercased() + humanized.dropFirst()
        }
    }
}
