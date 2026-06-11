import XCTest

@testable import LeafCore

final class SinceLastActiveItemComposeTests: XCTestCase {
    func test_compose_ghPrMerged_actorIsMe_renderYouMerged() {
        let feed = ActivityFeedItem(
            ts: 1_700_000_000_000,
            source: .github, eventKind: "gh_pr_merged",
            actorDisplay: nil, actorIsMe: true,
            targetTitle: "Add Track-11 substrate",
            targetRef: "PR#142",
            repoHint: "leaf",
            sourceURL: URL(string: "https://github.com/gundemtech/leaf/pull/142")
        )
        let item = SinceLastActiveItem.compose(from: feed)
        XCTAssertEqual(item?.verb, "merged")
        XCTAssertEqual(item?.actorPrefix, "you")
        XCTAssertEqual(item?.severity, .muted)
        XCTAssertEqual(item?.sourceMeta, "PR#142 · leaf")
    }

    func test_compose_ghPrReviewRequested_renderTeammateRequested() {
        let feed = ActivityFeedItem(
            ts: 1_700_000_000_000,
            source: .github, eventKind: "gh_pr_review_requested",
            actorDisplay: "anton", actorIsMe: false,
            targetTitle: "Refactor Sparkle gating",
            targetRef: "PR#143", repoHint: "leaf",
            sourceURL: nil
        )
        let item = SinceLastActiveItem.compose(from: feed)
        XCTAssertEqual(item?.verb, "requested your review on")
        XCTAssertEqual(item?.actorPrefix, "anton")
        XCTAssertEqual(item?.severity, .warn)
    }

    func test_compose_ghCommitPushed_actorIsMe() {
        let feed = ActivityFeedItem(
            ts: 1, source: .github, eventKind: "gh_commit_pushed",
            actorDisplay: nil, actorIsMe: true,
            targetTitle: "Add foo", targetRef: "feature/foo",
            repoHint: "leaf", sourceURL: nil
        )
        let item = SinceLastActiveItem.compose(from: feed)
        XCTAssertEqual(item?.verb, "pushed")
        XCTAssertEqual(item?.actorPrefix, "you")
        XCTAssertEqual(item?.severity, .muted)
    }

    func test_compose_blocker_renderDetectorPrefix() {
        let feed = ActivityFeedItem(
            ts: 1, source: .detection, eventKind: "blocker",
            actorDisplay: nil, actorIsMe: false,
            targetTitle: "Sasha needs Linear OAuth scope",
            targetRef: nil, sourceURL: nil
        )
        let item = SinceLastActiveItem.compose(from: feed)
        XCTAssertEqual(item?.verb, "blocker:")
        XCTAssertEqual(item?.actorPrefix, "")
        XCTAssertEqual(item?.severity, .danger)
    }

    func test_compose_openQuestion_renderDetectorPrefix() {
        let feed = ActivityFeedItem(
            ts: 1, source: .detection, eventKind: "open_question",
            actorDisplay: nil, actorIsMe: false,
            targetTitle: "Should we ship 5.4 this week?",
            targetRef: nil, sourceURL: nil
        )
        let item = SinceLastActiveItem.compose(from: feed)
        XCTAssertEqual(item?.verb, "open question:")
        XCTAssertEqual(item?.actorPrefix, "")
        XCTAssertEqual(item?.severity, .warn)
    }

    func test_compose_unmapped_eventKind_returnsNil() {
        let feed = ActivityFeedItem(
            ts: 1, source: .github, eventKind: "gh_unknown_kind",
            actorDisplay: nil, actorIsMe: false,
            targetTitle: nil, targetRef: nil, sourceURL: nil
        )
        XCTAssertNil(SinceLastActiveItem.compose(from: feed))
    }

    // Linear status_transition sub-discriminator coverage

    func test_compose_linearStatusStarted_renderStarted() {
        let feed = makeStatusTransition(toState: "started")
        XCTAssertEqual(SinceLastActiveItem.compose(from: feed)?.verb, "started")
    }
    func test_compose_linearStatusCompleted_renderCompleted() {
        XCTAssertEqual(
            SinceLastActiveItem.compose(from: makeStatusTransition(toState: "completed"))?.verb,
            "completed")
    }
    func test_compose_linearStatusCanceled_renderCanceled() {
        XCTAssertEqual(
            SinceLastActiveItem.compose(from: makeStatusTransition(toState: "canceled"))?.verb,
            "canceled")
    }
    func test_compose_linearStatusReopened_renderReopenedSeverityWarn() {
        let item = SinceLastActiveItem.compose(from: makeStatusTransition(toState: "reopened"))
        XCTAssertEqual(item?.verb, "reopened")
        XCTAssertEqual(item?.severity, .warn)
    }

    func test_compose_linearCommentToMe_severityWarn_teammateFallback() {
        let feed = ActivityFeedItem(
            ts: 1, source: .linear, eventKind: "linear_comment_authored_to_me",
            actorDisplay: nil, actorIsMe: false,
            targetTitle: "LEAF-200", targetRef: "LEAF-200",
            sourceURL: URL(string: "https://linear.app/leaf/issue/LEAF-200")
        )
        let item = SinceLastActiveItem.compose(from: feed)
        XCTAssertEqual(item?.verb, "commented on")
        XCTAssertEqual(item?.actorPrefix, "@teammate")
        XCTAssertEqual(item?.severity, .warn)
        // Home redesign — ref repeating the title is dropped from the meta line.
        XCTAssertEqual(item?.sourceMeta, "")
    }

    // Home redesign — meta-line noise fixes.

    func test_compose_ghMeta_dropsTargetRefWhenItDuplicatesTitle() {
        let feed = ActivityFeedItem(
            ts: 1, source: .github, eventKind: "gh_commit_pushed",
            actorDisplay: nil, actorIsMe: true,
            targetTitle: "feature/v1-ai", targetRef: "feature/v1-ai",
            repoHint: "leaf-relay", sourceURL: nil
        )
        let item = SinceLastActiveItem.compose(from: feed)
        XCTAssertEqual(item?.sourceMeta, "leaf-relay")
    }

    func test_compose_detectionMeta_humanLabel_noInternalTrackName() {
        let feed = ActivityFeedItem(
            ts: 1, source: .detection, eventKind: "open_question",
            actorDisplay: nil, actorIsMe: false,
            targetTitle: "Which KDF do we pick?", targetRef: nil, sourceURL: nil
        )
        let item = SinceLastActiveItem.compose(from: feed)
        XCTAssertEqual(item?.sourceMeta, "Detected by Leaf")
    }

    func test_compose_slackMention_actorFallback() {
        let feed = ActivityFeedItem(
            ts: 1, source: .slack, eventKind: "slack_mention_received_aggregate",
            actorDisplay: nil, actorIsMe: false,
            targetTitle: "engineering", targetRef: "#engineering",
            sourceURL: nil
        )
        let item = SinceLastActiveItem.compose(from: feed)
        XCTAssertEqual(item?.verb, "mentioned you in")
        XCTAssertEqual(item?.actorPrefix, "@teammate")
        XCTAssertEqual(item?.severity, .warn)
        XCTAssertEqual(item?.sourceMeta, "#engineering")
    }

    func test_compose_slackHuddle_actorIsMe() {
        let feed = ActivityFeedItem(
            ts: 1, source: .slack, eventKind: "slack_huddle_state_change",
            actorDisplay: nil, actorIsMe: true,
            targetTitle: nil, targetRef: nil, sourceURL: nil
        )
        let item = SinceLastActiveItem.compose(from: feed)
        XCTAssertEqual(item?.verb, "joined a huddle")
        XCTAssertEqual(item?.actorPrefix, "you")
        XCTAssertEqual(item?.severity, .muted)
    }

    private func makeStatusTransition(toState: String) -> ActivityFeedItem {
        ActivityFeedItem(
            ts: 1, source: .linear,
            eventKind: "linear_status_transition.\(toState)",
            actorDisplay: nil, actorIsMe: true,
            targetTitle: "LEAF-208", targetRef: "LEAF-208",
            repoHint: nil, sourceURL: nil
        )
    }
}
