// Phase 4.3 — minimal contract test for StubGitHubAPIProvider.
// Prod parser (REST events feed mapping + ADR-010 enforcement) tested separately
// in LeafCorePrivateTests/ProdGitHubAPIProviderTests.swift (moat, B5).

import XCTest
@testable import LeafCore

final class GitHubAPIProviderTests: XCTestCase {
    func testStubReturnsEmpty() async throws {
        let provider = StubGitHubAPIProvider()
        let result = try await provider.fetchEvents(accessToken: "t", login: "octocat", since: nil)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertNil(result.cursorMs)
    }

    func testStubIgnoresSince() async throws {
        let provider = StubGitHubAPIProvider()
        let result = try await provider.fetchEvents(accessToken: "t", login: "octocat", since: 1_700_000_000_000)
        XCTAssertEqual(result, .empty)
    }

    func testStubReturnsEmptyForWarmAndColdMethods() async throws {
        let stub = StubGitHubAPIProvider()

        let projects = try await stub.fetchProjectsV2State(accessToken: "", login: "x", topN: 10)
        XCTAssertEqual(projects.projects.count, 0)

        let gists = try await stub.fetchGists(accessToken: "", login: "x")
        XCTAssertEqual(gists.count, 0)

        let invs = try await stub.fetchRepoInvitations(accessToken: "")
        XCTAssertEqual(invs.count, 0)

        let codespaces = try await stub.fetchCodespaces(accessToken: "")
        XCTAssertEqual(codespaces.count, 0)

        let reactions = try await stub.fetchIssueReactions(accessToken: "", owner: "o", repo: "r", issueNumber: 1)
        XCTAssertEqual(reactions.byEmoji.count, 0)

        let starred = try await stub.fetchStarredRepos(accessToken: "", login: "x")
        XCTAssertEqual(starred.count, 0)

        let watched = try await stub.fetchWatchedRepos(accessToken: "", login: "x")
        XCTAssertEqual(watched.count, 0)

        let secret = try await stub.fetchSecretScanningAlerts(accessToken: "", owner: "o", repo: "r")
        XCTAssertEqual(secret.count, 0)

        let code = try await stub.fetchCodeScanningAlerts(accessToken: "", owner: "o", repo: "r")
        XCTAssertEqual(code.count, 0)

        let deps = try await stub.fetchDependabotAlerts(accessToken: "", owner: "o", repo: "r")
        XCTAssertEqual(deps.count, 0)

        let orgs = try await stub.fetchOrganizations(accessToken: "")
        XCTAssertEqual(orgs.count, 0)

        let audit = try await stub.fetchOrgAuditLog(accessToken: "", org: "o", since: nil)
        XCTAssertEqual(audit.entries.count, 0)
        XCTAssertNil(audit.cursorMs)
    }
}
