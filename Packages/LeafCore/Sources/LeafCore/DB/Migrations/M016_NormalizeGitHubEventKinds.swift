import Foundation
import GRDB

/// Phase Track-3 D2 — retroactive rename of pre-D2 GitHub event_kinds to the
/// canonical `gh_*` prefix. Idempotent: each UPDATE filters by the old name,
/// so subsequent migrate() calls (and historic re-installs) find zero rows.
public enum M016NormalizeGitHubEventKinds {
    /// 21 old → new mappings preserved verbatim. Source of truth for both the
    /// migration and DispatchCoverageTests.renameMappingCoverage().
    public static let renameMap: [(old: String, new: String)] = [
        ("commit_pushed", "gh_commit_pushed"),
        ("pr_opened", "gh_pr_opened"),
        ("pr_merged", "gh_pr_merged"),
        ("pr_closed", "gh_pr_closed"),
        ("issue_opened", "gh_issue_opened"),
        ("issue_closed", "gh_issue_closed"),
        ("review_submitted", "gh_pr_review_submitted"),
        ("pr_review_comment_authored", "gh_pr_review_comment_authored"),
        ("issue_comment_authored", "gh_issue_comment_authored"),
        ("release_published", "gh_release_published"),
        ("branch_created", "gh_branch_created"),
        ("branch_deleted", "gh_branch_deleted"),
        ("tag_created", "gh_tag_created"),
        ("discussion_authored", "gh_discussion_authored"),
        ("discussion_comment_authored", "gh_discussion_comment_authored"),
        ("pr_review_thread_resolved", "gh_pr_review_thread_resolved"),
        ("github_notifications_pulse", "gh_notifications_pulse"),
        ("pr_awaiting_review_count", "gh_pr_awaiting_review_count"),
        ("my_open_pr_count", "gh_my_open_pr_count"),
        ("actions_run_initiated", "gh_actions_run_initiated"),
        ("check_runs_status", "gh_check_runs_status"),
    ]

    public static func runRename(in db: GRDB.Database) throws {
        for (old, new) in renameMap {
            try db.execute(
                sql: """
                    UPDATE events
                    SET payload_json = json_set(payload_json, '$.event_kind', ?)
                    WHERE json_extract(payload_json, '$.event_kind') = ?
                    """, arguments: [new, old])
        }
    }
}

extension DatabaseMigrator {
    public mutating func registerMigration016NormalizeGitHubEventKinds() {
        registerMigration("016_normalize_github_event_kinds") { db in
            try M016NormalizeGitHubEventKinds.runRename(in: db)
        }
    }
}
