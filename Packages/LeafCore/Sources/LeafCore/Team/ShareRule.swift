import Foundation

/// Phase Track-5 S5 — single row of `share_rules` table. Stored per
/// (workspace_id, source) composite. Absence of row implies
/// `ShareRuleDefaults.isEnabledByDefault(_:)` semantics.
public struct ShareRule: Sendable, Equatable, Hashable {
    public let workspaceID: String
    public let source: ShareSource
    public let enabled: Bool
    public let updatedAtMs: Int64

    public init(workspaceID: String, source: ShareSource, enabled: Bool, updatedAtMs: Int64) {
        self.workspaceID = workspaceID
        self.source = source
        self.enabled = enabled
        self.updatedAtMs = updatedAtMs
    }
}

/// Phase Track-5 S5 — default enabled state per source per Track 5 contract §11.1.
///
/// ON by default (outcome-bearing or detection-of-high-confidence):
///   - gitCommits, linearIssues, detectedDecisions, detectedBlockers.
///
/// OFF by default (capture-everything locally, share-selectively per ADR-020 +
/// contract §11.1 "Privacy by default"):
///   - slackMentions, githubPRs, detectedOpenQuestions, detectedWhereStopped,
///     rawGitHubActivity.
public enum ShareRuleDefaults {
    public static let all: [ShareSource: Bool] = [
        .gitCommits:            true,
        .linearIssues:          true,
        .detectedDecisions:     true,
        .detectedBlockers:      true,
        .slackMentions:         false,
        .githubPRs:             false,
        .detectedOpenQuestions: false,
        .detectedWhereStopped:  false,
        .rawGitHubActivity:     false,
    ]

    public static func isEnabledByDefault(_ source: ShareSource) -> Bool {
        all[source] ?? false
    }
}
