import XCTest
@testable import LeafCore

/// Track-10 T2 — assert that gitDelta + currentTaskIdentity defaulted fields preserve
/// existing fixture callsites: convenience init without specifying either compiles +
/// the resulting snapshot reads nil on both.
final class InsightsSnapshotGitDeltaFieldsTests: XCTestCase {
    func testConvenienceInitOmittingGitDeltaCompilesAndReadsNil() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 600
        )
        XCTAssertNil(snapshot.gitDelta)
        XCTAssertNil(snapshot.currentTaskIdentity)
    }

    func testFullInitOmittingGitDeltaCompilesAndReadsNil() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionsCount: 0,
            deepWorkStreak: .empty,
            peakProductivityHour: nil,
            weekOverWeekDelta: nil,
            activeDaysInRow: 0,
            aiRatio: 0,
            aiActiveSeconds: 0,
            filesTouched: [],
            linearIssuesTouched: 0,
            linearByProject: [],
            linearByStatus: [],
            linearCompletionDurationStats: nil,
            githubEventsCount: 0,
            githubByRepo: [],
            githubByEventKind: [],
            githubPRCycleStats: nil,
            githubReviewDelayStats: nil,
            slackMessagesCount: 0,
            slackHuddleMinutes: 0,
            slackByChannel: []
        )
        XCTAssertNil(snapshot.gitDelta)
        XCTAssertNil(snapshot.currentTaskIdentity)
    }

    func testConvenienceInitExplicitGitDeltaPropagates() {
        let delta = GitDeltaSnapshot(
            commitsAhead: 4, commitsBehind: 0, uncommittedCount: 3,
            mergeBase: "origin/main",
            remote: GitRemoteRef(host: "github.com", owner: "gundemtech", repo: "leaf")
        )
        let identity = TaskIdentity(linearID: "LEAF-204", branch: "feature/track-10")
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 600,
            gitDelta: delta,
            currentTaskIdentity: identity
        )
        XCTAssertEqual(snapshot.gitDelta, delta)
        XCTAssertEqual(snapshot.currentTaskIdentity, identity)
    }
}
