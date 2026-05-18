import Foundation

public enum SameTaskMatcher {
    /// Minimum number of leading shared path segments (split on `/` and `-`, lowercased)
    /// for two branches to be considered adjacent. Tunable via this constant only —
    /// not exposed via user settings in Track 8 P1.
    private static let adjacentMinSharedSegments = 3

    /// Matches teammates against the caller's identity using the hierarchical rule:
    /// 1. `onSameLinearIssue` — both sides resolve to identical LEAF-NN.
    /// 2. `onSameBranch` — same repo AND identical branch name AND neither side has LEAF-NN.
    /// 3. `onAdjacentBranch` — same repo AND branches share ≥ `adjacentMinSharedSegments`
    ///    leading segments after splitting on `/` and `-`.
    /// Returns matches sorted: confidence priority asc, then `lastActivityAtMs` desc,
    /// then `displayName` asc (deterministic for tests).
    public static func match(myIdentity: TaskIdentity,
                             teammates: [TeammateSnapshot],
                             rule: MatchRule) -> [TeammateMatch] {
        guard !myIdentity.isEmpty else { return [] }
        switch rule {
        case .hierarchical:
            break
        }

        var out: [TeammateMatch] = []
        for t in teammates {
            if let mine = myIdentity.linearID, let theirs = t.linearID, mine == theirs {
                out.append(makeMatch(t, confidence: .onSameLinearIssue, contextLabel: "on \(mine)"))
                continue
            }
            if myIdentity.linearID == nil, t.linearID == nil,
               let mineRepo = myIdentity.repo, let theirsRepo = t.repo, mineRepo == theirsRepo,
               let mineBranch = myIdentity.branch, let theirsBranch = t.branch,
               mineBranch == theirsBranch {
                out.append(makeMatch(t, confidence: .onSameBranch, contextLabel: "same branch"))
                continue
            }
            if let mineRepo = myIdentity.repo, let theirsRepo = t.repo, mineRepo == theirsRepo,
               let mineBranch = myIdentity.branch, let theirsBranch = t.branch,
               sharedSegmentCount(mineBranch, theirsBranch) >= adjacentMinSharedSegments {
                out.append(makeMatch(t, confidence: .onAdjacentBranch, contextLabel: "adjacent branch"))
                continue
            }
        }

        out.sort { (a, b) in
            if a.confidence.sortRank != b.confidence.sortRank {
                return a.confidence.sortRank < b.confidence.sortRank
            }
            if a.lastActivityAtMs != b.lastActivityAtMs {
                return a.lastActivityAtMs > b.lastActivityAtMs
            }
            return a.displayName < b.displayName
        }
        return out
    }

    // MARK: - Helpers

    private static func makeMatch(_ t: TeammateSnapshot,
                                  confidence: MatchConfidence,
                                  contextLabel: String) -> TeammateMatch {
        TeammateMatch(
            memberID: t.memberID,
            displayName: t.displayName,
            currentApp: t.currentApp,
            durationSec: 0,
            confidence: confidence,
            contextLabel: contextLabel,
            lastActivityAtMs: t.lastActivityAtMs
        )
    }

    /// Splits each string by `/` and `-`, lowercases, and counts the longest common
    /// leading prefix of segments. Empty segments are dropped.
    static func sharedSegmentCount(_ a: String, _ b: String) -> Int {
        let segsA = splitSegments(a)
        let segsB = splitSegments(b)
        var count = 0
        for (sa, sb) in zip(segsA, segsB) {
            if sa == sb {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    private static func splitSegments(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { $0 == "/" || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
