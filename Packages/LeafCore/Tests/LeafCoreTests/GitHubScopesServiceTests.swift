// Phase Track-3 D2 — Task 12: GitHubScopesService actor tests.
//
// Covers:
//  - missing() against requiredCore (one-missing, all-present, all-missing).
//  - missingOptional() decoupled from missing() — informational only.
//  - has(_:) lookup semantics.
//  - refresh() reloads integrations.scope from Database.
//  - Whitespace-tolerant parse of GitHub's space-separated scope string.
//  - Empty / NULL scope → empty granted set.
//  - requested() = sorted union of required + optional.
//  - GitHubScopesChecking protocol conformance compiles.

import XCTest
@testable import LeafCore

final class GitHubScopesServiceTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-github-scopes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - missing() against requiredCore

    /// Granted = core minus one → missing returns just that one.
    func testMissingReturnsTheOneAbsentCoreScope() async {
        let granted: Set<String> = ["repo", "read:user", "read:org"]
        let s = GitHubScopesService(grantedOverride: granted)
        let missing = await s.missing()
        XCTAssertEqual(missing, ["read:project"])
    }

    /// Granted = supersetОфCore → missing empty.
    func testMissingEmptyWhenSuperset() async {
        let granted = GitHubScopesService.requiredCore.union(["unrelated:scope", "extra"])
        let s = GitHubScopesService(grantedOverride: granted)
        let missing = await s.missing()
        XCTAssertTrue(missing.isEmpty, "Expected empty missing set; got \(missing)")
    }

    /// Granted = empty → missing == requiredCore (full set).
    func testMissingFullCoreWhenEmptyGranted() async {
        let s = GitHubScopesService(grantedOverride: [])
        let missing = await s.missing()
        XCTAssertEqual(missing, GitHubScopesService.requiredCore)
    }

    // MARK: - has()

    func testHasReturnsTrueForGrantedScope() async {
        let s = GitHubScopesService(grantedOverride: ["repo", "read:user"])
        let result = await s.has("repo")
        XCTAssertTrue(result)
    }

    func testHasReturnsFalseForUngrantedScope() async {
        let s = GitHubScopesService(grantedOverride: ["repo"])
        let result = await s.has("read:org")
        XCTAssertFalse(result)
    }

    // MARK: - missingOptional() decoupled from missing()

    /// Granted = full requiredCore, no optional → missing empty,
    /// missingOptional contains both optional scopes. Optional gaps must NOT
    /// surface in `missing()` (they are informational, не blocking).
    func testMissingOptionalSeparatedFromMissing() async {
        let s = GitHubScopesService(grantedOverride: GitHubScopesService.requiredCore)

        let missing = await s.missing()
        XCTAssertTrue(missing.isEmpty, "Optional gaps must not appear in missing(); got \(missing)")

        let missingOpt = await s.missingOptional()
        XCTAssertEqual(missingOpt, GitHubScopesService.requiredOptional)
    }

    /// Optional partially granted → missingOptional reflects the gap.
    func testMissingOptionalShowsPartialGrant() async {
        var granted = GitHubScopesService.requiredCore
        granted.insert("security_events")
        let s = GitHubScopesService(grantedOverride: granted)
        let missingOpt = await s.missingOptional()
        XCTAssertEqual(missingOpt, ["read:audit_log"])
    }

    // MARK: - refresh() reloads from Database

    /// Mutate `integrations.scope` underneath the actor; refresh() picks up new state.
    func testRefreshReloadsFromDatabase() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.upsertIntegration(IntegrationRecord(
            provider: .github,
            workspaceID: "owner",
            workspaceName: "Owner",
            accessToken: "tok",
            refreshToken: nil,
            expiresAt: nil,
            scope: "repo",
            connectedAt: now,
            updatedAt: now
        ))

        let s = GitHubScopesService(database: db)

        let beforeOrg = await s.has("read:org")
        XCTAssertFalse(beforeOrg, "read:org must be absent before re-grant")
        let beforeRepo = await s.has("repo")
        XCTAssertTrue(beforeRepo)

        // User re-auths with broader scope set.
        try db.upsertIntegration(IntegrationRecord(
            provider: .github,
            workspaceID: "owner",
            workspaceName: "Owner",
            accessToken: "tok",
            refreshToken: nil,
            expiresAt: nil,
            scope: "repo read:org",
            connectedAt: now,
            updatedAt: now
        ))

        await s.refresh()

        let afterOrg = await s.has("read:org")
        XCTAssertTrue(afterOrg, "read:org must surface after refresh()")
        let afterRepo = await s.has("repo")
        XCTAssertTrue(afterRepo)
    }

    // MARK: - Database parse semantics

    /// Multi-space + leading/trailing whitespace tolerated → no empty tokens.
    func testWhitespaceTolerantParse() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.upsertIntegration(IntegrationRecord(
            provider: .github,
            workspaceID: "o", workspaceName: "n",
            accessToken: "t", refreshToken: nil, expiresAt: nil,
            scope: "  repo  read:user ",
            connectedAt: now, updatedAt: now
        ))

        let s = GitHubScopesService(database: db)
        let granted = await s.currentGranted()
        XCTAssertEqual(granted, ["repo", "read:user"])
    }

    /// Empty `scope` column → granted empty → missing == full requiredCore.
    func testEmptyScopeYieldsEmptyGranted() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.upsertIntegration(IntegrationRecord(
            provider: .github,
            workspaceID: "o", workspaceName: "n",
            accessToken: "t", refreshToken: nil, expiresAt: nil,
            scope: "",
            connectedAt: now, updatedAt: now
        ))

        let s = GitHubScopesService(database: db)
        let granted = await s.currentGranted()
        XCTAssertTrue(granted.isEmpty)
        let missing = await s.missing()
        XCTAssertEqual(missing, GitHubScopesService.requiredCore)
    }

    /// No integration row at all → granted empty → missing == full requiredCore.
    func testAbsentIntegrationYieldsEmptyGranted() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let s = GitHubScopesService(database: db)
        let granted = await s.currentGranted()
        XCTAssertTrue(granted.isEmpty)
        let missing = await s.missing()
        XCTAssertEqual(missing, GitHubScopesService.requiredCore)
    }

    // MARK: - requested()

    /// requested() returns deduped sorted union of required + optional.
    func testRequestedIsSortedUnion() {
        let expected = Array(
            GitHubScopesService.requiredCore.union(GitHubScopesService.requiredOptional)
        ).sorted()
        XCTAssertEqual(GitHubScopesService.requested(), expected)
        // Sanity — sorted invariant.
        let req = GitHubScopesService.requested()
        XCTAssertEqual(req, req.sorted())
    }

    // MARK: - Protocol conformance

    /// Compile-time assertion that GitHubScopesService satisfies GitHubScopesChecking.
    func testConformsToGitHubScopesChecking() async {
        let s: any GitHubScopesChecking = GitHubScopesService(grantedOverride: ["repo"])
        let result = await s.has("repo")
        XCTAssertTrue(result)
    }
}
