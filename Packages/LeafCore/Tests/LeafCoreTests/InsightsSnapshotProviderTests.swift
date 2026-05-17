import XCTest
@testable import LeafCore

/// Phase 4.2 / 4.4 / 4.6.A — per-provider breakdown round-trip on
/// `InsightsSnapshot`. Split from InsightsSnapshotTests for type_body_length.
final class InsightsSnapshotProviderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Phase 4.2 Linear

    func testEmptyWhenLinearZero() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            linearIssuesTouched: 0,
            linearByProject: [],
            linearByStatus: []
        )
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.linearIssuesTouched, 0)
    }

    func testNotEmptyWhenLinearIssuesPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            linearIssuesTouched: 3,
            linearByProject: [ProjectCountEntry(project: "Leaf", count: 3)],
            linearByStatus: [StatusCountEntry(status: "In Progress", count: 3)]
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.linearIssuesTouched, 3)
        XCTAssertEqual(snapshot.linearByProject.first?.project, "Leaf")
    }

    // MARK: - Phase 4.4 Slack

    func testEmptyWhenSlackZero() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            slackMessagesCount: 0,
            slackHuddleMinutes: 0,
            slackByChannel: []
        )
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.slackMessagesCount, 0)
        XCTAssertEqual(snapshot.slackHuddleMinutes, 0)
    }

    func testNotEmptyWhenSlackMessagesPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            slackMessagesCount: 7,
            slackByChannel: [SlackActivityBreakdown.ChannelCountEntry(channelName: "engineering", count: 7)]
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.slackMessagesCount, 7)
        XCTAssertEqual(snapshot.slackByChannel.first?.channelName, "engineering")
    }

    func testNotEmptyWhenSlackHuddleMinutesPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            slackHuddleMinutes: 30
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.slackHuddleMinutes, 30)
    }

    // MARK: - Phase 4.6.A.1 GitHub latency

    func testGithubLatencyStatsRoundTripWhenPresent() {
        let cycle = LatencyStats(medianSeconds: 1800, avgSeconds: 2000, maxSeconds: 3600, sampleCount: 3)
        let delay = LatencyStats(medianSeconds: 900, avgSeconds: 900, maxSeconds: 1200, sampleCount: 2)
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            githubEventsCount: 5,
            githubByRepo: [RepoCountEntry(repo: "octocat/leaf", count: 5)],
            githubByEventKind: [EventKindCountEntry(eventKind: "gh_pr_merged", count: 3)],
            githubPRCycleStats: cycle,
            githubReviewDelayStats: delay
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.githubPRCycleStats?.medianSeconds, 1800)
        XCTAssertEqual(snapshot.githubReviewDelayStats?.sampleCount, 2)
    }

    func testGithubLatencyStatsNilByDefault() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            githubEventsCount: 0
        )
        XCTAssertNil(snapshot.githubPRCycleStats)
        XCTAssertNil(snapshot.githubReviewDelayStats)
        XCTAssertTrue(snapshot.isEmpty, "no events + nil latency → empty")
    }

    func testLatencyStatsFromSamplesEvenCount() {
        // sorted: 100, 200, 300, 400 → median = (200+300)/2 = 250, avg=250, max=400.
        let stats = try? XCTUnwrap(LatencyStats.from(samples: [400, 100, 300, 200]))
        XCTAssertEqual(stats?.sampleCount, 4)
        XCTAssertEqual(stats?.medianSeconds, 250)
        XCTAssertEqual(stats?.avgSeconds, 250)
        XCTAssertEqual(stats?.maxSeconds, 400)
    }

    func testLatencyStatsFromEmptySamplesReturnsNil() {
        XCTAssertNil(LatencyStats.from(samples: []))
    }

    // MARK: - Phase 4.6.A.2 Linear completion duration

    func testLinearCompletionStatsRoundTripWhenPresent() {
        let dur = LatencyStats(medianSeconds: 7200, avgSeconds: 9000, maxSeconds: 14400, sampleCount: 3)
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            linearIssuesTouched: 3,
            linearByProject: [ProjectCountEntry(project: "Leaf", count: 3)],
            linearByStatus: [StatusCountEntry(status: "Done", count: 3)],
            linearCompletionDurationStats: dur
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.linearCompletionDurationStats?.medianSeconds, 7200)
        XCTAssertEqual(snapshot.linearCompletionDurationStats?.sampleCount, 3)
        XCTAssertEqual(snapshot.linearCompletionDurationStats?.maxSeconds, 14400)
    }

    func testLinearCompletionStatsNilByDefault() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            linearIssuesTouched: 0
        )
        XCTAssertNil(snapshot.linearCompletionDurationStats)
        XCTAssertTrue(snapshot.isEmpty, "no issues + nil completion stats → empty")
    }

    // MARK: - Phase 4.6.A.3 Slack reactions + huddle session stats

    func testSlackReactionsAndHuddleSessionStatsRoundTripWhenPresent() {
        let huddleStats = LatencyStats(medianSeconds: 1500, avgSeconds: 1500, maxSeconds: 2400, sampleCount: 3)
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            slackMessagesCount: 5,
            slackHuddleMinutes: 75,
            slackByChannel: [SlackActivityBreakdown.ChannelCountEntry(channelName: "engineering", count: 5)],
            slackReactionsReceived: 8,
            slackHuddleSessionStats: huddleStats
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.slackReactionsReceived, 8)
        XCTAssertEqual(snapshot.slackHuddleSessionStats?.sampleCount, 3)
        XCTAssertEqual(snapshot.slackHuddleSessionStats?.medianSeconds, 1500)
        XCTAssertEqual(snapshot.slackHuddleSessionStats?.maxSeconds, 2400)
    }

    func testSlackReactionsAndHuddleSessionStatsDefaultsBackwardCompat() {
        // Existing test/UI callsites без новых параметров не ломаются.
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            slackMessagesCount: 3
        )
        XCTAssertEqual(snapshot.slackReactionsReceived, 0, "default 0 для backward compat")
        XCTAssertNil(snapshot.slackHuddleSessionStats, "default nil")
        XCTAssertFalse(snapshot.isEmpty, "messages > 0 → не empty")
    }
}
