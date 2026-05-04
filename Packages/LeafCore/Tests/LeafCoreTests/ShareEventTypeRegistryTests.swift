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

    /// Phase 4.7.C — registry total 43 keys (4.7.B baseline 33 + 4.7.C 10).
    /// Если ломается при добавлении в 4.8/далее — обновить counter сознательно.
    func testPhase47CRegistrySize() {
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 43,
                       "Phase 4.7.C total = 33 prior + 10 new = 43 keys total")
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

    /// Phase 4.7.C — все 10 новых keys должны быть registered.
    func testPhase47CNewKeysPresent() {
        let phase47CKeys: [ShareEventTypeKey] = [
            .linearPriorityChanged,
            .linearLabelAdded,
            .linearLabelRemoved,
            .linearAssigneeChanged,
            .linearCycleChanged,
            .linearEstimateChanged,
            .linearProjectUpdateAuthored,
            .linearDocumentEdited,
            .linearInitiativeObserved,
            .githubPullRequestReviewThreadResolved
        ]
        XCTAssertEqual(phase47CKeys.count, 10, "Phase 4.7.C adds exactly 10 new keys")
        for key in phase47CKeys {
            XCTAssertNotNil(
                ShareEventTypeDefaults.all.first { $0.key == key },
                "Phase 4.7.C key \(key.rawValue) must have default entry"
            )
        }
    }

    /// Phase 4.7.C — defaults split: 8 ON (transition flavors + projectUpdate +
    /// pr_review_thread_resolved), 2 OFF (skeleton-style для unstable APIs:
    /// documents + initiatives — могут вернуть 0 events на legacy workspaces).
    func testPhase47CDefaults() {
        let onByDefault: Set<ShareEventTypeKey> = [
            .linearPriorityChanged, .linearLabelAdded, .linearLabelRemoved,
            .linearAssigneeChanged, .linearCycleChanged, .linearEstimateChanged,
            .linearProjectUpdateAuthored,
            .githubPullRequestReviewThreadResolved
        ]
        let offByDefault: Set<ShareEventTypeKey> = [
            .linearDocumentEdited, .linearInitiativeObserved
        ]
        let map = Dictionary(uniqueKeysWithValues:
            ShareEventTypeDefaults.all.map { ($0.key, $0.defaultEnabled) })
        for key in onByDefault {
            XCTAssertEqual(map[key], true, "\(key.rawValue) should be ON by default")
        }
        for key in offByDefault {
            XCTAssertEqual(map[key], false, "\(key.rawValue) should be OFF by default")
        }
    }

    /// Phase 4.7.C raw value literals — single source of truth между registry,
    /// runtime emission, и downstream SQL queries.
    func testPhase47CRawValueLiterals() {
        XCTAssertEqual(ShareEventTypeKey.linearPriorityChanged.rawValue, "linear_priority_changed")
        XCTAssertEqual(ShareEventTypeKey.linearLabelAdded.rawValue, "linear_label_added")
        XCTAssertEqual(ShareEventTypeKey.linearLabelRemoved.rawValue, "linear_label_removed")
        XCTAssertEqual(ShareEventTypeKey.linearAssigneeChanged.rawValue, "linear_assignee_changed")
        XCTAssertEqual(ShareEventTypeKey.linearCycleChanged.rawValue, "linear_cycle_changed")
        XCTAssertEqual(ShareEventTypeKey.linearEstimateChanged.rawValue, "linear_estimate_changed")
        XCTAssertEqual(ShareEventTypeKey.linearProjectUpdateAuthored.rawValue, "linear_project_update_authored")
        XCTAssertEqual(ShareEventTypeKey.linearDocumentEdited.rawValue, "linear_document_edited")
        XCTAssertEqual(ShareEventTypeKey.linearInitiativeObserved.rawValue, "linear_initiative_observed")
        XCTAssertEqual(ShareEventTypeKey.githubPullRequestReviewThreadResolved.rawValue, "pr_review_thread_resolved")
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
