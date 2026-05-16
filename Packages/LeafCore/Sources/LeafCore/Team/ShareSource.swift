import Foundation

/// Phase Track-5 S5 — coarse-grain auto-share groups (9 sources per Track 5
/// contract §11.1). Higher-level grouping above the 152-entry
/// `ShareEventTypeKey` registry; `ShareSourceClassifier` maps event_kinds onto
/// these values. RawValue mirrored in `Schema.ShareSources` for SQL consumers.
///
/// Single source of truth — `Schema.ShareSources` MUST stay lockstep with these
/// rawValues. CHECK constraint on `share_rules.source_kind` intentionally
/// omitted at the schema layer (precedent: `share_event_types` deferral noted
/// in `ShareEventTypeRegistry.swift`).
public enum ShareSource: String, Sendable, Codable, CaseIterable, Hashable {
    case gitCommits            = "git_commits"
    case linearIssues          = "linear_issues"
    case slackMentions         = "slack_mentions"
    case githubPRs             = "github_prs"
    case detectedDecisions     = "detected_decisions"
    case detectedBlockers      = "detected_blockers"
    case detectedOpenQuestions = "detected_open_questions"
    case detectedWhereStopped  = "detected_where_stopped"
    case rawGitHubActivity     = "raw_github_activity"
}

public extension ShareSource {
    /// Human-readable display name for UI chips and toggles.
    var displayName: String {
        switch self {
        case .gitCommits:            return "Git Commits"
        case .linearIssues:          return "Linear Issues"
        case .slackMentions:         return "Slack Mentions"
        case .githubPRs:             return "GitHub PRs"
        case .detectedDecisions:     return "Decisions"
        case .detectedBlockers:      return "Blockers"
        case .detectedOpenQuestions: return "Open Questions"
        case .detectedWhereStopped:  return "Where Stopped"
        case .rawGitHubActivity:     return "GitHub Activity"
        }
    }
}
