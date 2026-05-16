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

    /// Track 3 D1 — registry total 66 keys (Track-1 D3 baseline 48 + Track-3 D1 18 Linear deep sweep).
    /// Если ломается при добавлении в новые phase'ы — обновить counter сознательно.
    func testRegistrySize66AfterD1() {
        // Superseded by testCount116 after Track-3 D3 — kept as historical anchor.
        XCTAssertGreaterThanOrEqual(ShareEventTypeKey.allCases.count, 66,
                       "Registry must contain at least 66 keys (Track-3 D1 baseline)")
    }

    /// Track 3 D3 — registry total 116 keys (97 post-D2 + 19 new Slack deep sweep).
    /// Track 4 S1 grew it 116 → 125 (+9 architecture catch-up).
    /// Track-6 P1 grew it 152 → 168 (+16 Claude Code deep — 2 retroactive + 14 new).
    /// Track-6 P3 grew it 168 → 176 (+8 Browsers deep).
    /// Track-6 P4 grew it 176 → 182 (+6 Google Calendar Deep).
    /// Track-6 P2 grew it 182 → 188 (+6 Xcode Deep).
    /// Track-6 P5 grew it 188 → 191 (+3 Zoom Deep).
    func testCount116() {
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 191)
    }

    /// Track 3 D2 — все GitHub keys must use the canonical `gh_*` rawValue
    /// prefix mirroring `GitHubEventKindKey`.
    func testAllGitHubKeysHaveGhPrefix() {
        let githubKeys = ShareEventTypeKey.allCases.filter { $0.rawValue.contains("gh_") || $0.rawValue.hasPrefix("github_") }
        for key in githubKeys {
            XCTAssertTrue(key.rawValue.hasPrefix("gh_"),
                "GitHub key '\(key)' rawValue must start with gh_, got '\(key.rawValue)'")
        }
    }

    /// Track 3 D2 — все 31 новые GitHub kinds default OFF per ADR-020
    /// (capture-everything locally, share-selectively).
    func testNewD2GitHubKindsAllDefaultOff() {
        let new: Set<String> = [
            "gh_pr_review_submitted",  // discriminator-only upgrade — pre-existing data exists but new state field; treat as new
            "gh_issue_locked", "gh_issue_unlocked", "gh_workflow_manual_triggered",
            "gh_deployment_created", "gh_deployment_status_changed",
            "gh_repo_created", "gh_repo_forked",
            "gh_project_card_moved", "gh_project_iteration_changed", "gh_project_field_updated",
            "gh_gist_created", "gh_gist_updated", "gh_gist_deleted",
            "gh_repo_invitation_received", "gh_repo_invitation_accepted",
            "gh_codespace_created", "gh_codespace_started", "gh_codespace_stopped", "gh_codespace_deleted",
            "gh_issue_reaction_received",
            "gh_repo_starred", "gh_repo_unstarred", "gh_repo_watched", "gh_repo_unwatched",
            "gh_secret_alert_observed", "gh_secret_alert_resolved",
            "gh_code_alert_observed", "gh_code_alert_resolved",
            "gh_dependabot_alert_observed", "gh_dependabot_alert_resolved",
            "gh_audit_action_observed"
        ]
        let defaultsMap = Dictionary(uniqueKeysWithValues:
            ShareEventTypeDefaults.all.map { ($0.key.rawValue, $0.defaultEnabled) })
        for rawValue in new {
            XCTAssertEqual(defaultsMap[rawValue], false,
                "New D2 GitHub kind '\(rawValue)' must default OFF (ADR-020)")
        }
    }

    /// Track 3 D2 — fence: ShareEventTypeKey GitHub cases must mirror
    /// GitHubEventKindKey rawValues 1:1. Doubles as a Task 23 pre-fence.
    func testEnumRawValuesMatchGitHubEventKindKey() {
        let registryGhKinds = Set(ShareEventTypeKey.allCases.map { $0.rawValue }.filter { $0.hasPrefix("gh_") })
        let enumKinds = Set(GitHubEventKindKey.allCases.map { $0.rawValue })
        XCTAssertEqual(registryGhKinds, enumKinds,
            "ShareEventTypeKey GitHub raw values must match GitHubEventKindKey.allCases 1:1")
    }

    /// Phase Track-3 D1 — все 18 новых Linear kinds default OFF per ADR-020
    /// (capture-everything locally, share-selectively).
    func testTrack3D1KindsAreDefaultOff() {
        let d1Keys: Set<ShareEventTypeKey> = [
            .linearCommentReactionAdded, .linearRelationAdded, .linearRelationRemoved,
            .linearTriageItemPickedUp, .linearTriageItemResolved,
            .linearNotificationReceived, .linearNotificationRead, .linearNotificationArchived,
            .linearSubscriptionAdded, .linearSubscriptionRemoved,
            .linearCycleStarted, .linearCycleCompleted,
            .linearRoadmapStateObserved,
            .linearCustomViewCreated, .linearCustomViewUpdated, .linearCustomViewDeleted,
            .linearProjectMembershipAdded, .linearProjectMembershipRemoved
        ]
        XCTAssertEqual(d1Keys.count, 18, "D1 spec mandates 18 new kinds")
        let map = Dictionary(uniqueKeysWithValues: ShareEventTypeDefaults.all.map { ($0.key, $0.defaultEnabled) })
        for k in d1Keys {
            XCTAssertEqual(map[k], false, "D1 kind \(k.rawValue) must default OFF per ADR-020")
        }
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
        XCTAssertEqual(ShareEventTypeKey.githubPullRequestReviewThreadResolved.rawValue, "gh_pr_review_thread_resolved")
    }

    /// rawValue strings должны матчить плановые literal'ы — single source of truth
    /// между registry, runtime emission и downstream SQL queries.
    func testPhase47BRawValueLiterals() {
        XCTAssertEqual(ShareEventTypeKey.githubNotificationsPulse.rawValue, "gh_notifications_pulse")
        XCTAssertEqual(ShareEventTypeKey.githubPRAwaitingReviewCount.rawValue, "gh_pr_awaiting_review_count")
        XCTAssertEqual(ShareEventTypeKey.githubMyOpenPRCount.rawValue, "gh_my_open_pr_count")
        XCTAssertEqual(ShareEventTypeKey.githubActionsRunInitiated.rawValue, "gh_actions_run_initiated")
        XCTAssertEqual(ShareEventTypeKey.githubCheckRunsStatus.rawValue, "gh_check_runs_status")
        XCTAssertEqual(ShareEventTypeKey.linearAssignedWorkloadPulse.rawValue, "linear_assigned_workload_pulse")
        XCTAssertEqual(ShareEventTypeKey.linearCycleProgress.rawValue, "linear_cycle_progress")
        XCTAssertEqual(ShareEventTypeKey.slackPresenceState.rawValue, "slack_presence_state")
        XCTAssertEqual(ShareEventTypeKey.slackDNDState.rawValue, "slack_dnd_state")
        XCTAssertEqual(ShareEventTypeKey.slackMentionReceivedAggregate.rawValue, "slack_mention_received_aggregate")
        XCTAssertEqual(ShareEventTypeKey.slackFileUploadedAggregate.rawValue, "slack_file_uploaded_aggregate")
    }
}
