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

    func testStubFetchWarmStateReturnsEmpty() async throws {
        let stub = StubLinearGraphQLProvider()
        let cursors = LinearWarmCursors(notificationsSince: nil, cyclesSince: nil)
        let batch = try await stub.fetchWarmState(accessToken: "tok", cursors: cursors)
        XCTAssertEqual(batch.notifications.count, 0)
        XCTAssertEqual(batch.cyclesStarted.count, 0)
        XCTAssertEqual(batch.cyclesCompleted.count, 0)
        XCTAssertEqual(batch.subscribedIssueIds.count, 0)
        XCTAssertNil(batch.notificationCursorMs)
        XCTAssertNil(batch.cyclesCursorMs)
    }

    func testStubFetchColdStateReturnsEmpty() async throws {
        let stub = StubLinearGraphQLProvider()
        let batch = try await stub.fetchColdState(accessToken: "tok")
        XCTAssertEqual(batch.roadmaps.count, 0)
        XCTAssertEqual(batch.customViews.count, 0)
        XCTAssertEqual(batch.projectMemberships.count, 0)
    }

    func testLinearIssueBatchEmptyHasEmptyHotPiggyBackArrays() {
        let b = LinearIssueBatch.empty
        XCTAssertEqual(b.commentReactions.count, 0)
        XCTAssertEqual(b.relationAdditions.count, 0)
        XCTAssertEqual(b.relationRemovals.count, 0)
        XCTAssertEqual(b.triagePickedUp.count, 0)
        XCTAssertEqual(b.triageResolved.count, 0)
    }
}
