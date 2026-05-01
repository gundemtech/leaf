import Foundation

/// Phase 4.7.A — registry of canonical event_kinds для share-controls
/// whitelist (whitepaper Section 7 / Share Controls model).
///
/// **Scope в Phase 4.7.A:** code-level constants only. `share_event_types`
/// table ещё не создана — runtime UPSERT logic откладывается до Phase 5
/// prep / отдельной mini-migration. До тех пор registry служит single source
/// of truth для:
/// - downstream code (share-control filters могут assert'ить полный set
///   известных event_kinds);
/// - onboarding default presets (`ShareEventTypeDefaults`);
/// - test coverage (любой новый event_kind должен быть registered).
///
/// Naming: rawValue матчит discriminator value в `events.payload_json.event_kind`
/// 1-в-1 — single string identity между registry, runtime emission и downstream
/// SQL queries.
public enum ShareEventTypeKey: String, CaseIterable, Sendable, Hashable {
    // MARK: - Phase 4.4 baseline (already shipped в alpha.5/6)
    case slackMessageAuthored = "message_authored_aggregate"
    case slackHuddleStateChange = "huddle_state_change"
    case linearIssueUpdated = "issue_updated"
    case githubCommitPushed = "commit_pushed"
    case githubPROpened = "pr_opened"
    case githubPRMerged = "pr_merged"
    case githubPRClosed = "pr_closed"
    case githubReviewSubmitted = "review_submitted"
    case githubIssueOpened = "issue_opened"
    case githubIssueClosed = "issue_closed"

    // MARK: - Phase 4.6.B (alpha.7)
    case linearStatusTransition = "status_transition"

    // MARK: - Phase 4.7.A — wide cheap (this commit)
    case githubPRReviewCommentAuthored = "pr_review_comment_authored"
    case githubIssueCommentAuthored = "issue_comment_authored"
    case githubReleasePublished = "release_published"
    case githubBranchCreated = "branch_created"
    case githubBranchDeleted = "branch_deleted"
    case githubTagCreated = "tag_created"
    case githubDiscussionAuthored = "discussion_authored"
    case githubDiscussionCommentAuthored = "discussion_comment_authored"
    case slackThreadReplyAggregate = "slack_thread_reply_aggregate"
    case slackStatusChange = "slack_status_change"
    case linearCommentAuthored = "linear_comment_authored"
}

/// Phase 4.7.A — onboarding default enabled-state per event_kind.
/// Recommendation для UI Settings → Share Controls onboarding template
/// ("common dev defaults"). Юзер всегда может override per-key. Persistence
/// шкафа — Phase 5 prep (`share_event_types` table).
public struct ShareEventTypeDefault: Sendable, Hashable {
    public let key: ShareEventTypeKey
    public let defaultEnabled: Bool

    public init(key: ShareEventTypeKey, defaultEnabled: Bool) {
        self.key = key
        self.defaultEnabled = defaultEnabled
    }
}

public enum ShareEventTypeDefaults {
    /// Полный default set across baseline + Phase 4.7.A. Defaults reflect
    /// "common dev team" preset: outcome-bearing events default ON, niche
    /// social-feature events (discussions) default OFF.
    public static let all: [ShareEventTypeDefault] = [
        // Phase 4.4 baseline
        .init(key: .slackMessageAuthored, defaultEnabled: true),
        .init(key: .slackHuddleStateChange, defaultEnabled: true),
        .init(key: .linearIssueUpdated, defaultEnabled: true),
        .init(key: .githubCommitPushed, defaultEnabled: true),
        .init(key: .githubPROpened, defaultEnabled: true),
        .init(key: .githubPRMerged, defaultEnabled: true),
        .init(key: .githubPRClosed, defaultEnabled: true),
        .init(key: .githubReviewSubmitted, defaultEnabled: true),
        .init(key: .githubIssueOpened, defaultEnabled: true),
        .init(key: .githubIssueClosed, defaultEnabled: true),

        // Phase 4.6.B
        .init(key: .linearStatusTransition, defaultEnabled: true),

        // Phase 4.7.A — additions
        .init(key: .githubPRReviewCommentAuthored, defaultEnabled: true),
        .init(key: .githubIssueCommentAuthored, defaultEnabled: true),
        .init(key: .githubReleasePublished, defaultEnabled: true),
        .init(key: .githubBranchCreated, defaultEnabled: true),
        .init(key: .githubBranchDeleted, defaultEnabled: true),
        .init(key: .githubTagCreated, defaultEnabled: true),
        // Discussions — нишевые; OFF by default (юзер может включить).
        .init(key: .githubDiscussionAuthored, defaultEnabled: false),
        .init(key: .githubDiscussionCommentAuthored, defaultEnabled: false),
        .init(key: .slackThreadReplyAggregate, defaultEnabled: true),
        .init(key: .slackStatusChange, defaultEnabled: true),
        .init(key: .linearCommentAuthored, defaultEnabled: true)
    ]
}
