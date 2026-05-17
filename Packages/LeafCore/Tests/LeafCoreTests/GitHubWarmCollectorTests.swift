//
//  GitHubWarmCollectorTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D2 — Task 8. Integration-flavored tests for the
//  GitHubWarmCollector.performTick(now:) flow: empty integration skip,
//  bootstrap discipline (zero diff events on first tick, snapshots written),
//  scope gating (projectsV2 skipped without read:project), bounded fan-out cap
//  for issue reactions, codespace state-transition emission.
//

import XCTest
import os

import class GRDB.Row

@testable import LeafCore

final class GitHubWarmCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "gh-warm")

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-gh-warm-\(UUID().uuidString)", isDirectory: true)
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
        var fetchProjectsV2Called = false
        var fetchGistsCalled = false
        var fetchRepoInvitationsCalled = false
        var fetchCodespacesCalled = false
        var fetchIssueReactionsCallCount = 0

        var nextProjects: GitHubProjectsV2Snapshot = .empty
        var nextGists: [GitHubGistSnapshot] = []
        var nextInvitations: [GitHubRepoInvitationSnapshot] = []
        var nextCodespaces: [GitHubCodespaceSnapshot] = []
        var nextReactions: [String: GitHubIssueReactionsSnapshot] = [:]

        func setProjects(_ s: GitHubProjectsV2Snapshot) { nextProjects = s }
        func setGists(_ g: [GitHubGistSnapshot]) { nextGists = g }
        func setInvitations(_ i: [GitHubRepoInvitationSnapshot]) { nextInvitations = i }
        func setCodespaces(_ c: [GitHubCodespaceSnapshot]) { nextCodespaces = c }
        func setReactions(_ r: [String: GitHubIssueReactionsSnapshot]) { nextReactions = r }

        // Hot-tier no-ops.
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
        func fetchActionsRunsForActor(
            accessToken: String, login: String, repos: [String], since: Int64
        ) async throws -> [GitHubActionsRunSnapshot] { [] }
        func fetchCheckRunsForCommit(
            accessToken: String, repo: String, sha: String
        ) async throws -> GitHubCheckRunsSummary { .empty }
        func fetchContributionsCalendar(accessToken: String) async throws -> GitHubContributionsCalendar { .empty }

        // Warm tier.
        func fetchProjectsV2State(
            accessToken: String, login: String, topN: Int
        ) async throws -> GitHubProjectsV2Snapshot {
            fetchProjectsV2Called = true
            return nextProjects
        }
        func fetchGists(accessToken: String, login: String) async throws -> [GitHubGistSnapshot] {
            fetchGistsCalled = true
            return nextGists
        }
        func fetchRepoInvitations(accessToken: String) async throws -> [GitHubRepoInvitationSnapshot] {
            fetchRepoInvitationsCalled = true
            return nextInvitations
        }
        func fetchCodespaces(accessToken: String) async throws -> [GitHubCodespaceSnapshot] {
            fetchCodespacesCalled = true
            return nextCodespaces
        }
        func fetchIssueReactions(
            accessToken: String, owner: String, repo: String, issueNumber: Int
        ) async throws -> GitHubIssueReactionsSnapshot {
            fetchIssueReactionsCallCount += 1
            let key = "\(owner)/\(repo)#\(issueNumber)"
            return nextReactions[key]
                ?? .empty(owner: owner, repo: repo, issueNumber: issueNumber, nowMs: 0)
        }

        // Cold tier no-ops.
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
    }

    // MARK: - Helpers

    private func insertGitHubIntegration(_ db: Database, login: String = "alice") throws {
        try db.upsertIntegration(
            IntegrationRecord(
                provider: .github,
                workspaceID: "github:\(login)",
                workspaceName: login,
                accessToken: "tok",
                refreshToken: nil,  // long-lived OAuth App
                expiresAt: nil,
                scope: "repo,read:project",
                connectedAt: Date(),
                updatedAt: Date()
            ))
    }

    private func makeRefresher(_ db: Database) -> GitHubTokenRefresher {
        GitHubTokenRefresher(database: db, clientID: "cid")
    }

    private func makeCollector(
        _ db: Database,
        _ provider: SpyProvider,
        scope: any GitHubScopesChecking = AlwaysGrantedScopeService()
    ) -> GitHubWarmCollector {
        GitHubWarmCollector(
            database: db,
            provider: provider,
            refresher: makeRefresher(db),
            scopeService: scope,
            intervalSec: 900,
            logger: logger
        )
    }

    private func insertViewerAuthoredIssueEvent(
        _ db: Database,
        repo: String,
        number: Int,
        tsMs: Int64
    ) throws {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": "gh_issue_opened",
            "repo": repo,
            "title": "test",
            "number": String(number),
            "sha": "",
            "branch": "",
        ]
        try db.write([
            RawEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0),
                signalType: .action,
                bundleID: nil,
                payload: payload
            )
        ])
    }

    // MARK: - Tests

    func testSkipWhenNoIntegration() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let p = SpyProvider()
        let c = makeCollector(db, p)
        let r = await c.performTick()
        XCTAssertTrue(r.skipped)
        XCTAssertEqual(r.eventsEmitted, 0)
    }

    func testEmptyAllEndpoints_writesSnapshotsZeroEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        let p = SpyProvider()
        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(r.skipped)
        XCTAssertEqual(r.eventsEmitted, 0)
        // Confirm singleton snapshots were written even with empty arrays.
        try db.readSQL { raw in
            XCTAssertNotNil(
                try ProviderSnapshotsStore.read(
                    provider: "github",
                    snapshotKind: Schema.ProviderSnapshotKinds.githubGists,
                    in: raw))
            XCTAssertNotNil(
                try ProviderSnapshotsStore.read(
                    provider: "github",
                    snapshotKind: Schema.ProviderSnapshotKinds.githubCodespaces,
                    in: raw))
            XCTAssertNotNil(
                try ProviderSnapshotsStore.read(
                    provider: "github",
                    snapshotKind: Schema.ProviderSnapshotKinds.githubRepoInvitations,
                    in: raw))
        }
        // Offset row written with lastModifiedMs = nowMs.
        let off = try db.readOffset(
            collectorID: CollectorID.githubWarmPolling,
            sourceID: "github:warm:alice"
        )
        XCTAssertNotNil(off)
        XCTAssertEqual(off?.lastModifiedMs, 100_000)
    }

    func testFirstTickEmitsZeroDiffEvents_BootstrapsSnapshots() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        let p = SpyProvider()
        await p.setProjects(
            GitHubProjectsV2Snapshot(projects: [
                GitHubProjectV2Snapshot(
                    projectID: "p1", projectTitle: "Roadmap",
                    items: [
                        GitHubProjectV2ItemSnapshot(
                            itemID: "i1", projectID: "p1", title: "Foo",
                            status: "Todo", iterationID: nil,
                            fieldValues: ["Priority": "P1"], updatedAtMs: 1
                        )
                    ])
            ]))
        await p.setGists([
            GitHubGistSnapshot(
                gistID: "g1", description: "alpha",
                isPublic: true, createdAtMs: 1, updatedAtMs: 1)
        ])
        await p.setCodespaces([
            GitHubCodespaceSnapshot(
                codespaceName: "musical-octo", repoFullName: "o/r",
                state: "Available", createdAtMs: 1, lastUsedAtMs: nil)
        ])
        await p.setInvitations([
            GitHubRepoInvitationSnapshot(
                invitationID: "iv1", repoFullName: "o/r",
                inviterLogin: "bob", invitedAtMs: 1)
        ])
        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0, "Bootstrap: zero diff events on first tick")
        // ProjectV2 per-project snapshot written under prefixed kind.
        try db.readSQL { raw in
            let snap = try ProviderSnapshotsStore.read(
                provider: "github",
                snapshotKind: Schema.ProviderSnapshotKinds.githubProjectV2ItemsPrefix + "p1",
                in: raw
            )
            XCTAssertNotNil(snap)
        }
    }

    func testProjectsV2SkippedWhenReadProjectScopeMissing() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        let p = SpyProvider()
        let c = makeCollector(db, p, scope: ScopeServiceMissing(["read:project"]))
        _ = await c.performTick()
        let projectsCalled = await p.fetchProjectsV2Called
        let gistsCalled = await p.fetchGistsCalled
        XCTAssertFalse(projectsCalled, "Must skip projectsV2 without read:project scope")
        XCTAssertTrue(gistsCalled, "Other endpoints must still proceed")
    }

    func testGistCreatedEmittedOnSecondTick() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        // Seed prior snapshot with empty list.
        try db.writeSQL { raw in
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(
                    provider: "github",
                    snapshotKind: Schema.ProviderSnapshotKinds.githubGists,
                    snapshotJSON: "[]",
                    capturedAtMs: 0
                ), in: raw)
        }
        let p = SpyProvider()
        await p.setGists([
            GitHubGistSnapshot(
                gistID: "g1", description: "alpha",
                isPublic: true, createdAtMs: 1, updatedAtMs: 1)
        ])
        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        try db.readSQL { raw in
            let rows = try Row.fetchAll(raw, sql: "SELECT payload_json FROM events ORDER BY id ASC")
            let texts = rows.compactMap { $0["payload_json"] as String? }
            XCTAssertTrue(texts.contains { $0.contains("\"event_kind\":\"gh_gist_created\"") })
        }
    }

    func testCodespaceStateTransitionEmitsStartedThenStopped() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        // Seed prior snapshot: codespace existed in Shutdown state.
        let priorJSON = """
            [{"codespaceName":"musical-octo","repoFullName":"o/r","state":"Shutdown","createdAtMs":1,"lastUsedAtMs":null}]
            """
        try db.writeSQL { raw in
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(
                    provider: "github",
                    snapshotKind: Schema.ProviderSnapshotKinds.githubCodespaces,
                    snapshotJSON: priorJSON,
                    capturedAtMs: 0
                ), in: raw)
        }
        let p = SpyProvider()
        await p.setCodespaces([
            GitHubCodespaceSnapshot(
                codespaceName: "musical-octo", repoFullName: "o/r",
                state: "Available", createdAtMs: 1, lastUsedAtMs: 100)
        ])
        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1, "started transition emits 1")
        try db.readSQL { raw in
            let rows = try Row.fetchAll(raw, sql: "SELECT payload_json FROM events ORDER BY id ASC")
            let texts = rows.compactMap { $0["payload_json"] as String? }
            XCTAssertTrue(texts.contains { $0.contains("\"event_kind\":\"gh_codespace_started\"") })
        }
    }

    func testIssueReactionsBoundedFanOut_TopK() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        // Seed 15 viewer-authored issues; collector should call fetchIssueReactions
        // for at most issueReactionsTopK (10) of them.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        for i in 1...15 {
            try insertViewerAuthoredIssueEvent(
                db, repo: "octo/repo", number: i,
                tsMs: nowMs - Int64(i * 1000)  // each 1s older
            )
        }
        let p = SpyProvider()
        let c = makeCollector(db, p)
        _ = await c.performTick(now: now)
        let calls = await p.fetchIssueReactionsCallCount
        XCTAssertLessThanOrEqual(calls, GitHubWarmCollector.issueReactionsTopK)
        XCTAssertEqual(calls, GitHubWarmCollector.issueReactionsTopK)
    }

    func testIssueReactionsDelta_emitsReactionReceived() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertGitHubIntegration(db)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try insertViewerAuthoredIssueEvent(db, repo: "octo/repo", number: 7, tsMs: nowMs - 1000)
        // Seed prior reactions snapshot for this issue: 1 "+1" reaction.
        let priorJSON = #"{"owner":"octo","repo":"repo","issueNumber":7,"byEmoji":{"+1":1},"observedAtMs":0}"#
        try db.writeSQL { raw in
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(
                    provider: "github",
                    snapshotKind: Schema.ProviderSnapshotKinds.githubIssueReactionsPrefix + "octo/repo#7",
                    snapshotJSON: priorJSON,
                    capturedAtMs: 0
                ), in: raw)
        }
        let p = SpyProvider()
        await p.setReactions([
            "octo/repo#7": GitHubIssueReactionsSnapshot(
                owner: "octo", repo: "repo", issueNumber: 7,
                byEmoji: ["+1": 3, "heart": 1], observedAtMs: nowMs
            )
        ])
        let c = makeCollector(db, p)
        let r = await c.performTick(now: now)
        // 2 events: +1 delta of 2, heart delta of 1.
        XCTAssertEqual(r.eventsEmitted, 2)
        try db.readSQL { raw in
            let rows = try Row.fetchAll(
                raw,
                sql: """
                    SELECT payload_json FROM events
                    WHERE json_extract(payload_json, '$.event_kind') = 'gh_issue_reaction_received'
                    ORDER BY id ASC
                    """)
            XCTAssertEqual(rows.count, 2)
        }
    }
}
