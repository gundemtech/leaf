// Phase 4.2 — minimal contract test для StubLinearGraphQLProvider.
// Prod parser tested in LeafCorePrivateTests/ProdLinearGraphQLProviderTests.swift (moat).

import XCTest
@testable import LeafCore

final class LinearGraphQLProviderTests: XCTestCase {
    func testStubReturnsEmpty() async throws {
        let provider = StubLinearGraphQLProvider()
        let result = try await provider.fetchIssues(accessToken: "t", since: nil)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertNil(result.cursorMs)
    }

    func testStubIgnoresSince() async throws {
        let provider = StubLinearGraphQLProvider()
        let result = try await provider.fetchIssues(accessToken: "t", since: 1_700_000_000_000)
        XCTAssertEqual(result, .empty)
    }
}
