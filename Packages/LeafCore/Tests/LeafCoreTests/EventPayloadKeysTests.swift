// Phase Track-1 D1 — pin all 12 payload key string literals.

import XCTest
@testable import LeafCore

final class EventPayloadKeysTests: XCTestCase {
    func testKeyStability() {
        XCTAssertEqual(Schema.EventPayloadKeys.body, "body")
        XCTAssertEqual(Schema.EventPayloadKeys.bodyTruncated, "body_truncated")
        XCTAssertEqual(Schema.EventPayloadKeys.attachmentsJson, "attachments_json")
        XCTAssertEqual(Schema.EventPayloadKeys.commentBodiesJson, "comment_bodies_json")
        XCTAssertEqual(Schema.EventPayloadKeys.threadRepliesJson, "thread_replies_json")
        XCTAssertEqual(Schema.EventPayloadKeys.messagesJson, "messages_json")
        XCTAssertEqual(Schema.EventPayloadKeys.filesCount, "files_count")
        XCTAssertEqual(Schema.EventPayloadKeys.additions, "additions")
        XCTAssertEqual(Schema.EventPayloadKeys.deletions, "deletions")
        XCTAssertEqual(Schema.EventPayloadKeys.requestedReviewersJson, "requested_reviewers_json")
        XCTAssertEqual(Schema.EventPayloadKeys.mentionCount, "mention_count")
        XCTAssertEqual(Schema.EventPayloadKeys.linkCount, "link_count")
    }

    func testTrack3D1KeysHaveCanonicalSnakeCaseValues() {
        // Single-source-of-truth assertion: every new key must serialize to
        // snake_case (matches existing convention + downstream SQL filters).
        let pairs: [(String, String)] = [
            (Schema.EventPayloadKeys.notificationId, "notification_id"),
            (Schema.EventPayloadKeys.notificationKind, "notification_kind"),
            (Schema.EventPayloadKeys.notificationTitle, "notification_title"),
            (Schema.EventPayloadKeys.issueId, "issue_id"),
            (Schema.EventPayloadKeys.issueIdentifier, "issue_identifier"),
            (Schema.EventPayloadKeys.commentId, "comment_id"),
            (Schema.EventPayloadKeys.relationId, "relation_id"),
            (Schema.EventPayloadKeys.fromIssueId, "from_issue_id"),
            (Schema.EventPayloadKeys.fromIssueIdentifier, "from_issue_identifier"),
            (Schema.EventPayloadKeys.toIssueId, "to_issue_id"),
            (Schema.EventPayloadKeys.toIssueIdentifier, "to_issue_identifier"),
            (Schema.EventPayloadKeys.relationKind, "relation_kind"),
            (Schema.EventPayloadKeys.emoji, "emoji"),
            (Schema.EventPayloadKeys.teamId, "team_id"),
            (Schema.EventPayloadKeys.toStateName, "to_state_name"),
            (Schema.EventPayloadKeys.toStateType, "to_state_type"),
            (Schema.EventPayloadKeys.resolutionKind, "resolution_kind"),
            (Schema.EventPayloadKeys.cycleId, "cycle_id"),
            (Schema.EventPayloadKeys.cycleNumber, "cycle_number"),
            (Schema.EventPayloadKeys.cycleName, "cycle_name"),
            (Schema.EventPayloadKeys.viewId, "view_id"),
            (Schema.EventPayloadKeys.viewName, "view_name"),
            (Schema.EventPayloadKeys.roadmapId, "roadmap_id"),
            (Schema.EventPayloadKeys.roadmapName, "roadmap_name"),
            (Schema.EventPayloadKeys.projectId, "project_id"),
            (Schema.EventPayloadKeys.projectName, "project_name"),
            (Schema.EventPayloadKeys.stateEnum, "state_enum"),
            (Schema.EventPayloadKeys.issuesCompletedCount, "issues_completed_count"),
            (Schema.EventPayloadKeys.progress, "progress"),
            (Schema.EventPayloadKeys.observedAtMs, "observed_at_ms"),
            (Schema.EventPayloadKeys.receivedAtMs, "received_at_ms"),
            (Schema.EventPayloadKeys.readAtMs, "read_at_ms"),
            (Schema.EventPayloadKeys.archivedAtMs, "archived_at_ms"),
            (Schema.EventPayloadKeys.reactedAtMs, "reacted_at_ms"),
            (Schema.EventPayloadKeys.startedAtMs, "started_at_ms"),
            (Schema.EventPayloadKeys.endsAtMs, "ends_at_ms"),
            (Schema.EventPayloadKeys.completedAtMs, "completed_at_ms"),
            (Schema.EventPayloadKeys.removedAtMs, "removed_at_ms")
        ]
        for (key, expected) in pairs {
            XCTAssertEqual(key, expected, "EventPayloadKey \(expected) drifted to \(key)")
        }
    }

    func testTrack3D1BodyKindNotificationTitle() {
        XCTAssertEqual(Schema.BodyKinds.linearNotificationTitle, "linear_notification_title")
    }

    func testTrack3D1CollectorIDWarmColdConstants() {
        XCTAssertEqual(CollectorID.linearWarmPolling, "linear_warm_polling")
        XCTAssertEqual(CollectorID.linearColdPolling, "linear_cold_polling")
    }
}
