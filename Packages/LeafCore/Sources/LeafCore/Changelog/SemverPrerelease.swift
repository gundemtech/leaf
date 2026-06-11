import Foundation

/// A SemVer 2.0 version with prerelease ordering, used by `WhatsNewTracker` to
/// decide whether the running build is newer than the last release the user saw.
///
/// The load-bearing detail: prerelease numeric identifiers compare by INTEGER, not
/// by string. Leaf ships `1.0.0-alpha.N`; a string compare would rank `alpha.9`
/// above `alpha.28` and silently suppress every What's New past alpha.9.
///
/// Precedence follows semver §11: major/minor/patch numerically; a version with a
/// prerelease has LOWER precedence than the same version without; prerelease
/// identifiers compare left-to-right (numeric by value, alphanumeric lexically,
/// numeric < alphanumeric, fewer fields < more when all preceding are equal).
public struct SemverPrerelease: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [Identifier]

    public enum Identifier: Equatable, Sendable {
        case numeric(Int)
        case alphanumeric(String)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// Parse "X.Y.Z" or "X.Y.Z-pre.release.ids". Returns nil for anything that is
    /// not a well-formed numeric triple (+ optional prerelease) — callers treat an
    /// unparseable version as "don't present" rather than guessing.
    public init?(_ string: String) {
        // Build metadata ("+...") is ignored for precedence (semver §10); strip it.
        let core = string.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let dashSplit = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let triple = dashSplit[0].split(separator: ".", omittingEmptySubsequences: false)
        guard triple.count == 3,
              let ma = Int(triple[0]), let mi = Int(triple[1]), let pa = Int(triple[2]),
              ma >= 0, mi >= 0, pa >= 0
        else { return nil }
        self.major = ma
        self.minor = mi
        self.patch = pa

        if dashSplit.count == 2 {
            let raw = dashSplit[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !raw.isEmpty, raw.allSatisfy({ !$0.isEmpty }) else { return nil }
            self.prerelease = raw.map { part in
                if let n = Int(part), String(n) == part { return .numeric(n) }
                return .alphanumeric(String(part))
            }
        } else {
            self.prerelease = []
        }
    }

    public static func == (lhs: SemverPrerelease, rhs: SemverPrerelease) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    public static func < (lhs: SemverPrerelease, rhs: SemverPrerelease) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Equal core. A prerelease has lower precedence than the normal version.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false       // equal releases
        case (true, false): return false       // lhs is GA, rhs is prerelease → lhs > rhs
        case (false, true): return true        // lhs is prerelease, rhs is GA → lhs < rhs
        case (false, false): break
        }

        // Compare prerelease identifiers left to right.
        for (l, r) in zip(lhs.prerelease, rhs.prerelease) {
            if l == r { continue }
            switch (l, r) {
            case let (.numeric(a), .numeric(b)): return a < b
            case let (.alphanumeric(a), .alphanumeric(b)): return a < b
            case (.numeric, .alphanumeric): return true       // numeric < alphanumeric
            case (.alphanumeric, .numeric): return false
            }
        }
        // All shared identifiers equal → the shorter set has lower precedence.
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
