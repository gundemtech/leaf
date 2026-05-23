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
        XCTAssertEqual(item?.sourceMeta, "LEAF-200")
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

    // MARK: - Coalesce (carry C-T5-10 fix-bundle)

    func test_coalesce_collapsesDuplicateLinearCommentToMeRows() {
        let feed = (1...5).map { i in
            ActivityFeedItem(
                ts: Int64(1_700_000_000_000 + i * 1000),
                source: .linear, eventKind: "linear_comment_authored_to_me",
                actorDisplay: nil, actorIsMe: false,
                targetTitle: "GUN-46", targetRef: "GUN-46",
                repoHint: nil,
                sourceURL: URL(string: "https://linear.app/leaf/issue/GUN-46")
            )
        }
        let composed = feed.compactMap(SinceLastActiveItem.compose(from:))
        XCTAssertEqual(composed.count, 5)
        let coalesced = SinceLastActiveItem.coalesce(composed)
        XCTAssertEqual(coalesced.count, 1)
        XCTAssertEqual(coalesced[0].aggregatedCount, 5)
        XCTAssertEqual(coalesced[0].tsMs, 1_700_000_000_000 + 5 * 1000)  // max ts wins
    }

    func test_coalesce_distinctTargetsStaySeparate() {
        let gun46 = ActivityFeedItem(
            ts: 1, source: .linear, eventKind: "linear_comment_authored_to_me",
            actorDisplay: nil, actorIsMe: false,
            targetTitle: "GUN-46", targetRef: "GUN-46",
            repoHint: nil, sourceURL: nil)
        let gun45 = ActivityFeedItem(
            ts: 2, source: .linear, eventKind: "linear_comment_authored_to_me",
            actorDisplay: nil, actorIsMe: false,
            targetTitle: "GUN-45", targetRef: "GUN-45",
            repoHint: nil, sourceURL: nil)
        let composed = [gun46, gun46, gun45, gun45, gun45].compactMap(SinceLastActiveItem.compose(from:))
        let coalesced = SinceLastActiveItem.coalesce(composed)
        XCTAssertEqual(coalesced.count, 2)
        let bySource = Dictionary(grouping: coalesced) { $0.sourceMeta }
        XCTAssertEqual(bySource["GUN-46"]?.first?.aggregatedCount, 2)
        XCTAssertEqual(bySource["GUN-45"]?.first?.aggregatedCount, 3)
    }

    func test_coalesce_distinctEventKindsStaySeparate() {
        let merged = ActivityFeedItem(
            ts: 1, source: .github, eventKind: "gh_pr_merged",
            actorDisplay: nil, actorIsMe: true,
            targetTitle: "Add foo", targetRef: "PR#142", repoHint: "leaf",
            sourceURL: nil)
        let opened = ActivityFeedItem(
            ts: 2, source: .github, eventKind: "gh_pr_opened",
            actorDisplay: nil, actorIsMe: true,
            targetTitle: "Add foo", targetRef: "PR#142", repoHint: "leaf",
            sourceURL: nil)
        let composed = [merged, opened].compactMap(SinceLastActiveItem.compose(from:))
        let coalesced = SinceLastActiveItem.coalesce(composed)
        XCTAssertEqual(coalesced.count, 2)  // distinct verbs "merged" / "opened"
    }

    func test_coalesce_d3DetectionsWithDistinctExcerpts_stayUnique() {
        let q1 = ActivityFeedItem(
            ts: 1, source: .detection, eventKind: "open_question",
            actorDisplay: nil, actorIsMe: false,
            targetTitle: "Should we ship 5.4?", targetRef: nil, sourceURL: nil)
        let q2 = ActivityFeedItem(
            ts: 2, source: .detection, eventKind: "open_question",
            actorDisplay: nil, actorIsMe: false,
            targetTitle: "Bump Sparkle to 2.7?", targetRef: nil, sourceURL: nil)
        let composed = [q1, q2, q1].compactMap(SinceLastActiveItem.compose(from:))
        let coalesced = SinceLastActiveItem.coalesce(composed)
        XCTAssertEqual(coalesced.count, 2)
    }

    func test_coalesce_emptyInput_returnsEmpty() {
        XCTAssertEqual(SinceLastActiveItem.coalesce([]), [])
    }
}
