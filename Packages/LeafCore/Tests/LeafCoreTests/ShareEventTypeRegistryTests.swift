import XCTest
@testable import LeafCore

final class ShareEventTypeRegistryTests: XCTestCase {

    /// Каждый case в `ShareEventTypeKey.allCases` должен иметь default entry —
    /// guard против забытого default'а при добавлении нового event_kind.
    func testAllKeysHaveDefaults() {
        let allKeys = Set(ShareEventTypeKey.allCases.map { $0.rawValue })
        let defaultKeys = Set(ShareEventTypeDefaults.all.map { $0.key.rawValue })
        XCTAssertEqual(allKeys, defaultKeys,
                       "Each ShareEventTypeKey case must have ShareEventTypeDefault entry")
    }

    /// rawValue uniqueness — два case'а не могут иметь одинаковый
    /// payload.event_kind discriminator.
    func testKeysAreUnique() {
        let raws = ShareEventTypeKey.allCases.map { $0.rawValue }
        XCTAssertEqual(Set(raws).count, raws.count, "All event_kind raws must be unique")
    }

    /// Phase 4.7.B — registry total 33 keys (4.4=10 + 4.6.B=1 + 4.7.A=11 +
    /// 4.7.B=11). Если этот тест ломается при добавлении 4.7.C/далее —
    /// обновить counter сознательно.
    func testPhase47BRegistrySize() {
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 33,
                       "Phase 4.7.B total = 22 prior + 11 new = 33 keys total")
    }

    /// Discussions default OFF (нишевые). Verify that key design intent сохранён.
    func testDiscussionsDefaultOff() {
        let dDefault = ShareEventTypeDefaults.all.first { $0.key == .githubDiscussionAuthored }
        XCTAssertEqual(dDefault?.defaultEnabled, false)
        let dcDefault = ShareEventTypeDefaults.all.first { $0.key == .githubDiscussionCommentAuthored }
        XCTAssertEqual(dcDefault?.defaultEnabled, false)
    }

    /// Phase 4.7.B — все 11 новых keys должны быть registered и defaultEnabled=true.
    /// Любая регрессия (missing key / wrong default) — сразу видна.
    func testPhase47BNewKeysDefaults() {
        let phase47BKeys: [ShareEventTypeKey] = [
            .githubNotificationsPulse,
            .githubPRAwaitingReviewCount,
            .githubMyOpenPRCount,
            .githubActionsRunInitiated,
            .githubCheckRunsStatus,
            .linearAssignedWorkloadPulse,
            .linearCycleProgress,
            .slackPresenceState,
            .slackDNDState,
            .slackMentionReceivedAggregate,
            .slackFileUploadedAggregate
        ]
        XCTAssertEqual(phase47BKeys.count, 11, "Phase 4.7.B adds exactly 11 new keys")

        for key in phase47BKeys {
            let entry = ShareEventTypeDefaults.all.first { $0.key == key }
            XCTAssertNotNil(entry, "Phase 4.7.B key \(key.rawValue) must have default entry")
            XCTAssertEqual(entry?.defaultEnabled, true,
                           "Phase 4.7.B key \(key.rawValue) defaults to enabled per design")
        }
    }

    /// rawValue strings должны матчить плановые literal'ы — single source of truth
    /// между registry, runtime emission и downstream SQL queries.
    func testPhase47BRawValueLiterals() {
        XCTAssertEqual(ShareEventTypeKey.githubNotificationsPulse.rawValue, "github_notifications_pulse")
        XCTAssertEqual(ShareEventTypeKey.githubPRAwaitingReviewCount.rawValue, "pr_awaiting_review_count")
        XCTAssertEqual(ShareEventTypeKey.githubMyOpenPRCount.rawValue, "my_open_pr_count")
        XCTAssertEqual(ShareEventTypeKey.githubActionsRunInitiated.rawValue, "actions_run_initiated")
        XCTAssertEqual(ShareEventTypeKey.githubCheckRunsStatus.rawValue, "check_runs_status")
        XCTAssertEqual(ShareEventTypeKey.linearAssignedWorkloadPulse.rawValue, "linear_assigned_workload_pulse")
        XCTAssertEqual(ShareEventTypeKey.linearCycleProgress.rawValue, "linear_cycle_progress")
        XCTAssertEqual(ShareEventTypeKey.slackPresenceState.rawValue, "slack_presence_state")
        XCTAssertEqual(ShareEventTypeKey.slackDNDState.rawValue, "slack_dnd_state")
        XCTAssertEqual(ShareEventTypeKey.slackMentionReceivedAggregate.rawValue, "slack_mention_received_aggregate")
        XCTAssertEqual(ShareEventTypeKey.slackFileUploadedAggregate.rawValue, "slack_file_uploaded_aggregate")
    }
}
