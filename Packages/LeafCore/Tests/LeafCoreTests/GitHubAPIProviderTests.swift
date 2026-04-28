// Phase 4.3 — minimal contract test для StubGitHubAPIProvider.
// Prod parser (REST events feed mapping + ADR-010 enforcement) tested separately
// в LeafCorePrivateTests/ProdGitHubAPIProviderTests.swift (moat, B5).

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
}
