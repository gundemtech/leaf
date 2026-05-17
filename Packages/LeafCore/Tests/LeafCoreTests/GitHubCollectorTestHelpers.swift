// Shared mock provider + fixture helpers for GitHubCollector*Tests files.
// Split from GitHubCollectorTests.swift for type_body_length / file_length.

import XCTest
import os

@testable import LeafCore

enum GitHubCollectorTestSupport {
    static let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "github-collector")

    /// Captures `since` argument для assertion в тестах. Каждый `setBatch(_:)`
    /// заменяет следующий return value.
    actor MockGitHubAPIProvider: GitHubAPIProvider {
        private(set) var sinceCalls: [Int64?] = []
        private(set) var loginCalls: [String] = []
        private(set) var notificationsCallCount: Int = 0
        private(set) var reviewQueueCallCount: Int = 0
        private(set) var myOpenPRsCallCount: Int = 0
        private(set) var actionsRunsCallCount: Int = 0
        private(set) var actionsRunsReposReceived: [[String]] = []
        private(set) var actionsRunsSinceReceived: [Int64] = []
        private(set) var checkRunsCallCount: Int = 0
        private(set) var checkRunsArgsReceived: [(repo: String, sha: String)] = []
        private(set) var contributionsCallCount: Int = 0
        private var batchToReturn: GitHubEventBatch = .empty
        private var notificationsSummaryToReturn: GitHubNotificationsSummary?
        private var reviewQueueSummaryToReturn: GitHubReviewQueueSummary?
        private var myOpenPRsSummaryToReturn: GitHubMyOpenPRsSummary?
        private var actionsRunsToReturn: [GitHubActionsRunSnapshot] = []
        // Per-(repo, sha) check-runs response keyed by "repo|sha"; default — `.empty`.
        private var checkRunsByKey: [String: GitHubCheckRunsSummary] = [:]
        private var contributionsCalendarToReturn: GitHubContributionsCalendar = .empty

        func fetchEvents(accessToken: String, login: String, since: Int64?) async throws -> GitHubEventBatch {
            sinceCalls.append(since)
            loginCalls.append(login)
            return batchToReturn
        }

        // Phase 4.7.B-1 — default returns empty pulse если test не setNotificationsSummary;
        // позволяет существующим тестам компилиться без модификации (они проверяют
        // events from setBatch(_:), pulse — orthogonal channel).
        func fetchNotifications(accessToken: String) async throws -> GitHubNotificationsSummary {
            notificationsCallCount += 1
            return notificationsSummaryToReturn
                ?? .empty(
                    nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                )
        }

        // Phase 4.7.B-2 — defaults к `.empty` для backwards compat с existing тестами,
        // которые сосредоточены на batch events / cursor flow.
        func fetchPRsAwaitingReview(accessToken: String, login: String) async throws -> GitHubReviewQueueSummary {
            reviewQueueCallCount += 1
            return reviewQueueSummaryToReturn
                ?? .empty(
                    nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                )
        }

        func fetchMyOpenPRs(accessToken: String, login: String) async throws -> GitHubMyOpenPRsSummary {
            myOpenPRsCallCount += 1
            return myOpenPRsSummaryToReturn
                ?? .empty(
                    nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                )
        }

        // Phase 4.7.B-3 — defaults к `[]` для backwards compat. setActionsRuns(_:)
        // переопределяет результат для тестов, exercise'ующих action runs explicitly.
        // Existing тесты используют signalType=.action filter assuming только batch
        // events; default empty actions runs preserves этот invariant.
        func fetchActionsRunsForActor(
            accessToken: String, login: String, repos: [String], since: Int64
        ) async throws -> [GitHubActionsRunSnapshot] {
            actionsRunsCallCount += 1
            actionsRunsReposReceived.append(repos)
            actionsRunsSinceReceived.append(since)
            return actionsRunsToReturn
        }

        // Phase 4.7.B-4 — defaults к `.empty` для backwards compat. setCheckRuns(_:_:_:)
        // переопределяет per-(repo, sha) — другие pairs всё равно return `.empty`.
        func fetchCheckRunsForCommit(
            accessToken: String, repo: String, sha: String
        ) async throws -> GitHubCheckRunsSummary {
            checkRunsCallCount += 1
            checkRunsArgsReceived.append((repo: repo, sha: sha))
            return checkRunsByKey["\(repo)|\(sha)"] ?? .empty
        }

        // Phase 4.7.B-5 — contributions calendar; defaults к `.empty` (todayCount=0).
        // Используется только когда collector сам решает fetch (cooldown gate).
        func fetchContributionsCalendar(accessToken: String) async throws -> GitHubContributionsCalendar {
            contributionsCallCount += 1
            return contributionsCalendarToReturn
        }

        // Phase Track-3 D2 — warm + cold tier mock conformance (no-op defaults; specific
        // expectations come in Tasks 8/10 collector tests).
        func fetchProjectsV2State(
            accessToken: String, login: String, topN: Int
        ) async throws -> GitHubProjectsV2Snapshot { .empty }
        func fetchGists(accessToken: String, login: String) async throws -> [GitHubGistSnapshot] { [] }
        func fetchRepoInvitations(accessToken: String) async throws -> [GitHubRepoInvitationSnapshot] { [] }
        func fetchCodespaces(accessToken: String) async throws -> [GitHubCodespaceSnapshot] { [] }
        func fetchIssueReactions(
            accessToken: String, owner: String, repo: String, issueNumber: Int
        ) async throws -> GitHubIssueReactionsSnapshot {
            .empty(owner: owner, repo: repo, issueNumber: issueNumber, nowMs: 0)
        }
        func fetchStarredRepos(accessToken: String, login: String) async throws -> [GitHubStarredRepoSnapshot] { [] }
        func fetchWatchedRepos(accessToken: String, login: String) async throws -> [GitHubWatchedRepoSnapshot] { [] }
        func fetchSecretScanningAlerts(
            accessToken: String, owner: String, repo: String
        ) async throws -> [GitHubSecurityAlertSnapshot] { [] }
        func fetchCodeScanningAlerts(
            accessToken: String, owner: String, repo: String
        ) async throws -> [GitHubSecurityAlertSnapshot] { [] }
        func fetchDependabotAlerts(
            accessToken: String, owner: String, repo: String
        ) async throws -> [GitHubSecurityAlertSnapshot] { [] }
        func fetchOrganizations(accessToken: String) async throws -> [GitHubOrgSnapshot] { [] }
        func fetchOrgAuditLog(accessToken: String, org: String, since: Int64?) async throws -> GitHubOrgAuditLogBatch {
            .empty
        }

        func setBatch(_ batch: GitHubEventBatch) {
            self.batchToReturn = batch
        }

        func setNotificationsSummary(_ summary: GitHubNotificationsSummary) {
            self.notificationsSummaryToReturn = summary
        }

        func setReviewQueueSummary(_ summary: GitHubReviewQueueSummary) {
            self.reviewQueueSummaryToReturn = summary
        }

        func setMyOpenPRsSummary(_ summary: GitHubMyOpenPRsSummary) {
            self.myOpenPRsSummaryToReturn = summary
        }

        func setActionsRuns(_ runs: [GitHubActionsRunSnapshot]) {
            self.actionsRunsToReturn = runs
        }

        func setCheckRuns(repo: String, sha: String, summary: GitHubCheckRunsSummary) {
            self.checkRunsByKey["\(repo)|\(sha)"] = summary
        }

        func setContributionsCalendar(_ calendar: GitHubContributionsCalendar) {
            self.contributionsCalendarToReturn = calendar
        }

        func calls() -> [Int64?] { sinceCalls }
        func logins() -> [String] { loginCalls }
        func notificationsCalls() -> Int { notificationsCallCount }
        func reviewQueueCalls() -> Int { reviewQueueCallCount }
        func myOpenPRsCalls() -> Int { myOpenPRsCallCount }
        func actionsRunsCalls() -> Int { actionsRunsCallCount }
        func actionsRunsRepos() -> [[String]] { actionsRunsReposReceived }
        func checkRunsCalls() -> Int { checkRunsCallCount }
        func checkRunsArgs() -> [(repo: String, sha: String)] { checkRunsArgsReceived }
        func contributionsCalls() -> Int { contributionsCallCount }
    }

    /// `workspaceID = "github:<login>"` per Phase 4.3 OAuth service convention;
    /// `workspaceName` хранит raw login (без префикса) — используется как path-сегмент
    /// `/users/<login>/events`.
    static func insertFreshIntegration(
        db: Database,
        login: String = "octocat",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws {
        let record = IntegrationRecord(
            provider: .github,
            workspaceID: "github:\(login)",
            workspaceName: login,
            accessToken: "test-token",
            refreshToken: "refresh-token",
            expiresAt: expiresAt,
            scope: "repo,read:user",
            connectedAt: Date(),
            updatedAt: Date()
        )
        try db.upsertIntegration(record)
    }
}
