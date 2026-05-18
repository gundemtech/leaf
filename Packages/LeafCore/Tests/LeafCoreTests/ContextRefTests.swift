import XCTest

@testable import LeafCore

final class ContextRefTests: XCTestCase {
    func testEquatable_slackThread_sameTsEqual() {
        XCTAssertEqual(
            ContextRef.slackThread(ts: "1700000000.123456"),
            ContextRef.slackThread(ts: "1700000000.123456"))
    }

    func testEquatable_slackThread_differentTsUnequal() {
        XCTAssertNotEqual(
            ContextRef.slackThread(ts: "1700000000.123456"),
            ContextRef.slackThread(ts: "1700000000.999999"))
    }

    func testEquatable_linearIssue_sameRefEqual() {
        XCTAssertEqual(
            ContextRef.linearIssue(ref: "LEAF-142"),
            ContextRef.linearIssue(ref: "LEAF-142"))
    }

    func testEquatable_githubPR_sameRefEqual() {
        XCTAssertEqual(
            ContextRef.githubPR(ref: "owner/repo#42"),
            ContextRef.githubPR(ref: "owner/repo#42"))
    }

    func testEquatable_acrossCasesUnequal() {
        XCTAssertNotEqual(
            ContextRef.slackThread(ts: "x"),
            ContextRef.linearIssue(ref: "x"))
    }

    func testHashable_insertableIntoSet() {
        let set: Set<ContextRef> = [
            .slackThread(ts: "ts1"),
            .slackThread(ts: "ts1"),
            .linearIssue(ref: "LEAF-1"),
        ]
        XCTAssertEqual(set.count, 2)
    }
}
