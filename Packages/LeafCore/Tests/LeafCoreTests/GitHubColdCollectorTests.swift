//
//  GitHubColdCollectorTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D2 — Task 10. Integration-flavored tests for
//  `GitHubColdCollector.performTick(now:)`:
//   - empty-integration skip
//   - bootstrap discipline (zero diff events on first tick, snapshots written)
//   - scope gating: missing `security_events` → skip 3 alert endpoints; warn
//     fires once per session
//   - audit log skipped when org list empty (personal account)
//   - active repos top-10 fan-out cap
//   - state-transition emission for security alerts (open→fixed → resolved;
//     resolved→open → observed)
//

import XCTest
import class GRDB.Row
import os
@testable import LeafCore

final class GitHubColdCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "gh-cold")

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-gh-cold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fakes

    private struct AlwaysGrantedScopeService: GitHubScopesChecking {
        func has(_ scope: String) async -> Bool { true }
    }

    private struct ScopeServiceMissing: GitHubScopesChecking {
        let missing: Set<String>
        init(_ missing: Set<String>) { self.missing = missing }
        func has(_ scope: String) async -> Bool { !missing.contains(scope) }
    }

    private actor SpyProvider: GitHubAPIProvider {
        // Cold counters.
        var fetchStarredCalled = false
        var fetchWatchedCalled = false
        var fetchSecretCallCount = 0
        var fetchCodeCallCount = 0
        var fetchDependabotCallCount = 0
        var fetchOrgsCalled = false
        var fetchAuditCallCount = 0

        var nextStarred: [GitHubStarredRepoSnapshot] = []
        var nextWatched: [GitHubWatchedRepoSnapshot] = []
        var nextSecret: [String: [GitHubSecurityAlertSnapshot]] = [:]
        var nextCode: [String: [GitHubSecurityAlertSnapshot]] = [:]
        var nextDependabot: [String: [GitHubSecurityAlertSnapshot]] = [:]
        var nextOrgs: [GitHubOrgSnapshot] = []
        var nextAudit: GitHubOrgAuditLogBatch = .empty

        func setStarred(_ s: [GitHubStarredRepoSnapshot]) { nextStarred = s }
        func setWatched(_ w: [GitHubWatchedRepoSnapshot]) { nextWatched = w }
        func setSecret(_ s: [String: [GitHubSecurityAlertSnapshot]]) { nextSecret = s }
        func setCode(_ s: [String: [GitHubSecurityAlertSnapshot]]) { nextCode = s }
        func setDependabot(_ s: [String: [GitHubSecurityAlertSnapshot]]) { nextDependabot = s }
        func setOrgs(_ o: [GitHubOrgSnapshot]) { nextOrgs = o }
        func setAudit(_ b: GitHubOrgAuditLogBatch) { nextAudit = b }

        // Hot tier no-ops.
        func fetchEvents(accessToken: String, login: String, since: Int64?) async throws -> GitHubEventBatch { .empty }
        func fetchNotifications(accessToken: String) async throws -> GitHubNotificationsSummary {
            .empty(nowMs: 0)
        }
        func fetchPRsAwaitingReview(accessToken: String, login: String) async throws -> GitHubReviewQueueSummary {
            .empty(nowMs: 0)
        }
        func fetchMyOpenPRs(accessToken: String, login: String) async throws -> GitHubMyOpenPRsSummary {
            .empty(nowMs: 0)
        }
        func fetchActionsRunsForActor(accessToken: String, login: String, repos: [String], since: Int64) async throws -> [GitHubActionsRunSnapshot] { [] }
        func fetchCheckRunsForCommit(accessToken: String, repo: String, sha: String) async throws -> GitHubCheckRunsSummary { .empty }
        func fetchContributionsCalendar(accessToken: String) async throws -> GitHubContributionsCalendar { .empty }

        // Warm tier no-ops.
        func fetchProjectsV2State(accessToken: String, login: String, topN: Int) async throws -> GitHubProjectsV2Snapshot { .empty }
        func fetchGists(accessToken: String, login: String) async throws -> [GitHubGistSnapshot] { [] }
        func fetchRepoInvitations(accessToken: String) async throws -> [GitHubRepoInvitationSnapshot] { [] }
        func fetchCodespaces(accessToken: String) async throws -> [GitHubCodespaceSnapshot] { [] }
        func fetchIssueReactions(accessToken: String, owner: String, repo: String, issueNumber: Int) async throws -> GitHubIssueReactionsSnapshot {
            .empty(owner: owner, repo: repo, issueNumber: issueNumber, nowMs: 0)
        }

        // Cold tier.
        func fetchStarredRepos(accessToken: String, login: String) async throws -> [GitHubStarredRepoSnapshot] {
            fetchStarredCalled = true
            return nextStarred
        }
        func fetchWatchedRepos(accessToken: String, login: String) async throws -> [GitHubWatchedRepoSnapshot] {
            fetchWatchedCalled = true
            return nextWatched
        }
        func fetchSecretScanningAlerts(accessToken: String, owner: String, repo: String) async throws -> [GitHubSecurityAlertSnapshot] {
            fetchSecretCallCount += 1
            return nextSecret["\(owner)/\(repo)"] ?? []
        }
        func fetchCodeScanningAlerts(accessToken: String, owner: String, repo: String) async throws -> [GitHubSecurityAlertSnapshot] {
            fetchCodeCallCount += 1
            return nextCode["\(owner)/\(repo)"] ?? []
        }
        func fetchDependabotAlerts(accessToken: String, owner: String, repo: String) async throws -> [GitHubSecurityAlertSnapshot] {
            fetchDependabotCallCount += 1
            return nextDependabot["\(owner)/\(repo)"] ?? []
        }
        func fetchOrganizations(accessToken: String) async throws -> [GitHubOrgSnapshot] {
            fetchOrgsCalled = true
            return nextOrgs
        }
        func fetchOrgAuditLog(accessToken: String, org: String, since: Int64?) async throws -> GitHubOrgAuditLogBatch {
            fetchAuditCallCount += 1
            return nextAudit
        }
    }

    // MARK: - Helpers

    private func insertGitHubIntegration(_ db: Database, login: String = "alice") throws {
        try db.upsertIntegration(IntegrationRecord(
            provider: .github,
            workspaceID: "github:\(login)",
            workspaceName: login,
            accessToken: "tok",
            refreshToken: nil,
            expiresAt: nil,
            scope: "repo,security_events,read:audit_log",
            connectedAt: Date(),
            updatedAt: Date()
        ))
    }

    private func insertActiveRepoEvent(_ db: Database, repo: String, tsMs: Int64) throws {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": "gh_commit_pushed",
            "repo": repo,
            "title": "wip",
            "sha": "abc",
            "branch": "main"
        ]
        try db.write([RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )])
    }

    private func makeRefresher(_ db: Database) -> GitHubTokenRefresher {
        GitHubTokenRefresher(database: db, clientID: "cid")
    }

    private func makeCollector(
        _ db: Database, _ provider: SpyProvider,
        scope: any GitHubScopesChecking = AlwaysGrantedScopeService()
    ) -> GitHubColdCollector {
        GitHubColdCollector(
            database: db, provider: provider,
            refresher: makeRefresher(db),
            scopeService: scope, intervalSec: 86_400,
            logger: logger
        )
    }

    // MARK: - Tests

    func testEmptyIntegrationSkip() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let p = SpyProvider()
        let c = makeCollector(db, p)
        let r = await c.performTick()
        XCTAssertTrue(r.skipped)
        XCTAssertEqual(r.eventsEmitted, 0)
    }

    func testFirstTickEmitsZeroDiffEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        let p = SpyProvider()
        await p.setStarred([GitHubStarredRepoSnapshot(repoFullName: "octo/repo", starredAtMs: 1)])
        await p.setWatched([GitHubWatchedRepoSnapshot(repoFullName: "octo/repo")])
        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(r.skipped)
        XCTAssertEqual(r.eventsEmitted, 0, "Bootstrap: snapshots written, no diff events")
        try db.readSQL { raw in
            XCTAssertNotNil(try ProviderSnapshotsStore.read(
                provider: "github",
                snapshotKind: Schema.ProviderSnapshotKinds.githubStarredRepos, in: raw))
            XCTAssertNotNil(try ProviderSnapshotsStore.read(
                provider: "github",
                snapshotKind: Schema.ProviderSnapshotKinds.githubWatchedRepos, in: raw))
        }
        let off = try db.readOffset(
            collectorID: CollectorID.githubColdPolling,
            sourceID: "github:cold:alice"
        )
        XCTAssertNotNil(off)
        XCTAssertEqual(off?.lastModifiedMs, 100_000)
    }

    func testSecondTickEmitsStarredDiff() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        // Seed prior starred snapshot with one repo.
        try db.writeSQL { raw in
            try ProviderSnapshotsStore.upsert(ProviderSnapshot(
                provider: "github",
                snapshotKind: Schema.ProviderSnapshotKinds.githubStarredRepos,
                snapshotJSON: #"{"repos":["a/b"]}"#, capturedAtMs: 0
            ), in: raw)
        }
        let p = SpyProvider()
        await p.setStarred([
            GitHubStarredRepoSnapshot(repoFullName: "a/b", starredAtMs: 1),
            GitHubStarredRepoSnapshot(repoFullName: "c/d", starredAtMs: 2)
        ])
        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1, "1 new starred")
        try db.readSQL { raw in
            let rows = try Row.fetchAll(raw, sql: "SELECT payload_json FROM events ORDER BY id ASC")
            let texts = rows.compactMap { $0["payload_json"] as String? }
            XCTAssertTrue(texts.contains { $0.contains("\"event_kind\":\"gh_repo_starred\"") })
        }
    }

    func testSecurityEndpointsSkippedWhenSecurityEventsScopeMissing() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        // Ensure there's an active repo so without scope-gate the loop would call.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try insertActiveRepoEvent(db, repo: "octo/repo", tsMs: nowMs - 1000)
        let p = SpyProvider()
        let c = makeCollector(db, p, scope: ScopeServiceMissing(["security_events"]))
        _ = await c.performTick(now: now)
        let secret = await p.fetchSecretCallCount
        let code = await p.fetchCodeCallCount
        let depbot = await p.fetchDependabotCallCount
        XCTAssertEqual(secret, 0, "Skip secret-scanning fetch without security_events scope")
        XCTAssertEqual(code, 0, "Skip code-scanning fetch without security_events scope")
        XCTAssertEqual(depbot, 0, "Skip dependabot fetch without security_events scope")

        // Second tick: warn must not fire again (one-shot per session).
        _ = await c.performTick(now: now.addingTimeInterval(100))
        let secret2 = await p.fetchSecretCallCount
        XCTAssertEqual(secret2, 0, "Still skipped on subsequent tick")
        // Behavioural check on warn discipline: instance flag flipped after first tick.
        let warnedOnce = await c.didLogSecurityScopeWarn
        XCTAssertTrue(warnedOnce)
    }

    func testAuditLogSkippedOnPersonalAccount() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        let p = SpyProvider()
        await p.setOrgs([]) // empty — personal account
        let c = makeCollector(db, p)
        _ = await c.performTick(now: Date(timeIntervalSince1970: 100))
        let audit = await p.fetchAuditCallCount
        XCTAssertEqual(audit, 0, "Personal account: no audit log fetch")
    }

    func testAuditLogSkippedWhenScopeMissingEvenWithOrgs() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        let p = SpyProvider()
        await p.setOrgs([GitHubOrgSnapshot(login: "myorg")])
        let c = makeCollector(db, p, scope: ScopeServiceMissing(["read:audit_log"]))
        _ = await c.performTick(now: Date(timeIntervalSince1970: 100))
        let audit = await p.fetchAuditCallCount
        XCTAssertEqual(audit, 0, "Missing read:audit_log scope: silent skip")
    }

    func testAuditLogFetchedAndEmitted() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        let p = SpyProvider()
        await p.setOrgs([GitHubOrgSnapshot(login: "myorg")])
        await p.setAudit(GitHubOrgAuditLogBatch(
            entries: [
                GitHubAuditLogEntry(action: "repo.create", actorLogin: "alice", createdAtMs: 1_000),
                GitHubAuditLogEntry(action: "team.add_member", actorLogin: "bob", createdAtMs: 2_000)
            ],
            cursorMs: 2_000
        ))
        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertGreaterThanOrEqual(r.eventsEmitted, 2)
        try db.readSQL { raw in
            let rows = try Row.fetchAll(raw, sql: """
                SELECT payload_json FROM events
                WHERE json_extract(payload_json, '$.event_kind') = 'gh_audit_action_observed'
                ORDER BY id ASC
                """)
            XCTAssertEqual(rows.count, 2)
        }
        // Cursor snapshot persisted.
        try db.readSQL { raw in
            let snap = try ProviderSnapshotsStore.read(
                provider: "github",
                snapshotKind: Schema.ProviderSnapshotKinds.githubAuditCursor,
                in: raw
            )
            XCTAssertNotNil(snap)
            XCTAssertTrue(snap!.snapshotJSON.contains("2000"))
        }
    }

    func testTopTenActiveReposFanOutCap() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        let now = Date(timeIntervalSince1970: 10_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        // Seed 25 distinct repos with `gh_commit_pushed` events within the
        // 14-day window; collector should fan-out to at most 10.
        for i in 0..<25 {
            try insertActiveRepoEvent(db, repo: "owner/repo\(i)", tsMs: nowMs - Int64(i * 60_000))
        }
        let p = SpyProvider()
        let c = makeCollector(db, p)
        _ = await c.performTick(now: now)
        let secret = await p.fetchSecretCallCount
        let code = await p.fetchCodeCallCount
        let depbot = await p.fetchDependabotCallCount
        XCTAssertEqual(secret, GitHubColdCollector.alertReposTopN)
        XCTAssertEqual(code, GitHubColdCollector.alertReposTopN)
        XCTAssertEqual(depbot, GitHubColdCollector.alertReposTopN)
    }

    func testAlertStateTransitionEmissionResolved() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        let now = Date(timeIntervalSince1970: 10_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try insertActiveRepoEvent(db, repo: "octo/repo", tsMs: nowMs - 1000)
        // Seed prior secret-alerts snapshot for this repo: one OPEN alert #1.
        let priorJSON = #"{"alerts":[{"kind":"secret","repoFullName":"octo/repo","alertNumber":1,"severity":"high","rule":"AKIA","packageName":null,"state":"open","createdAtMs":1,"updatedAtMs":2}]}"#
        try db.writeSQL { raw in
            try ProviderSnapshotsStore.upsert(ProviderSnapshot(
                provider: "github",
                snapshotKind: Schema.ProviderSnapshotKinds.githubSecretAlertsPrefix + "octo/repo",
                snapshotJSON: priorJSON, capturedAtMs: 0
            ), in: raw)
        }
        let p = SpyProvider()
        await p.setSecret([
            "octo/repo": [
                GitHubSecurityAlertSnapshot(
                    kind: .secret, repoFullName: "octo/repo", alertNumber: 1,
                    severity: "high", rule: "AKIA", packageName: nil,
                    state: "fixed", createdAtMs: 1, updatedAtMs: 5
                )
            ]
        ])
        let c = makeCollector(db, p)
        let r = await c.performTick(now: now)
        XCTAssertGreaterThanOrEqual(r.eventsEmitted, 1)
        try db.readSQL { raw in
            let rows = try Row.fetchAll(raw, sql: """
                SELECT payload_json FROM events
                WHERE json_extract(payload_json, '$.event_kind') = 'gh_secret_alert_resolved'
                """)
            XCTAssertEqual(rows.count, 1, "open→fixed transition emits resolved")
        }
    }

    func testAlertStateTransitionReopenObserved() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        let now = Date(timeIntervalSince1970: 10_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try insertActiveRepoEvent(db, repo: "octo/repo", tsMs: nowMs - 1000)
        // Seed prior code-alerts snapshot: one FIXED alert #2.
        let priorJSON = #"{"alerts":[{"kind":"code","repoFullName":"octo/repo","alertNumber":2,"severity":"medium","rule":"CWE-79","packageName":null,"state":"fixed","createdAtMs":1,"updatedAtMs":2}]}"#
        try db.writeSQL { raw in
            try ProviderSnapshotsStore.upsert(ProviderSnapshot(
                provider: "github",
                snapshotKind: Schema.ProviderSnapshotKinds.githubCodeAlertsPrefix + "octo/repo",
                snapshotJSON: priorJSON, capturedAtMs: 0
            ), in: raw)
        }
        let p = SpyProvider()
        await p.setCode([
            "octo/repo": [
                GitHubSecurityAlertSnapshot(
                    kind: .code, repoFullName: "octo/repo", alertNumber: 2,
                    severity: "medium", rule: "CWE-79", packageName: nil,
                    state: "open", createdAtMs: 1, updatedAtMs: 5
                )
            ]
        ])
        let c = makeCollector(db, p)
        _ = await c.performTick(now: now)
        try db.readSQL { raw in
            let rows = try Row.fetchAll(raw, sql: """
                SELECT payload_json FROM events
                WHERE json_extract(payload_json, '$.event_kind') = 'gh_code_alert_observed'
                """)
            XCTAssertEqual(rows.count, 1, "fixed→open re-observation emits observed")
        }
    }
}
