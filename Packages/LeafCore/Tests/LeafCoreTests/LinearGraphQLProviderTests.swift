// Phase 4.2 — minimal contract test for StubLinearGraphQLProvider.
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

    // Track-9 T2 — incomingCommentCount field round-trip.
    // Discriminator counterpart to commentCountInWindow (outbound, viewer's own
    // comments). incomingCommentCount tallies comments authored BY OTHERS on
    // viewer-touched issues — the substrate seed for linear_comment_authored_to_me.
    func test_linearIssueSnapshot_incomingCommentCount_defaultsToZero() {
        let snap = LinearIssueSnapshot(
            issueKey: "LEA-200",
            title: "X",
            status: "In Progress",
            project: "",
            teamKey: "LEA",
            updatedAtMs: 1_715_900_000_000
        )
        XCTAssertEqual(snap.incomingCommentCount, 0)
    }

    func test_linearIssueSnapshot_incomingCommentCount_roundTripsExplicit() {
        let snap = LinearIssueSnapshot(
            issueKey: "LEA-200",
            title: "X",
            status: "In Progress",
            project: "",
            teamKey: "LEA",
            updatedAtMs: 1_715_900_000_000,
            incomingCommentCount: 3
        )
        XCTAssertEqual(snap.incomingCommentCount, 3)
    }

    // Track-9 T2 — workspaceSlug round-trip. urlKey piggybacks `organization { urlKey }`
    // GraphQL fragment in LeafPoll viewer block (zero new HTTP). Parser-side cached in
    // LinearCollector actor state; payload `linear_issue_url` composition consumes.
    func test_linearIssueBatch_workspaceSlug_defaultsNil() {
        let b = LinearIssueBatch(issues: [], cursorMs: nil)
        XCTAssertNil(b.workspaceSlug)
    }

    func test_linearIssueBatch_workspaceSlug_roundTripsExplicit() {
        let b = LinearIssueBatch(
            issues: [],
            cursorMs: nil,
            workspaceSlug: "my-team"
        )
        XCTAssertEqual(b.workspaceSlug, "my-team")
    }
}
