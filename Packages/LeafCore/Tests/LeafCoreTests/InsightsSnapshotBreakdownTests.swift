import XCTest
@testable import LeafCore

/// Phase 4.6.C.1 + 4.6.C.3 — wowDeltaPct + per-provider streaks на
/// Linear/GitHub/Slack breakdown structs. Split from InsightsSnapshotTests
/// for type_body_length.
final class InsightsSnapshotBreakdownTests: XCTestCase {

    // MARK: - Phase 4.6.C.1 — wowDeltaPct в breakdown structs

    func testLinearBreakdownWowDeltaPctDefaultNil() {
        let bd = LinearActivityBreakdown(
            issuesTouched: 3,
            byProject: [],
            byStatus: []
        )
        XCTAssertNil(bd.wowDeltaPct, "default nil — backwards compat")
    }

    func testLinearBreakdownWowDeltaPctExplicit() {
        let bd = LinearActivityBreakdown(
            issuesTouched: 3,
            byProject: [],
            byStatus: [],
            wowDeltaPct: 0.12
        )
        XCTAssertEqual(bd.wowDeltaPct, 0.12)
    }

    func testGithubBreakdownWowDeltaPctDefaultNil() {
        let bd = GitHubActivityBreakdown(
            eventsCount: 5,
            byRepo: [],
            byEventKind: []
        )
        XCTAssertNil(bd.wowDeltaPct)
    }

    func testGithubBreakdownWowDeltaPctExplicit() {
        let bd = GitHubActivityBreakdown(
            eventsCount: 5,
            byRepo: [],
            byEventKind: [],
            wowDeltaPct: -0.05
        )
        XCTAssertEqual(bd.wowDeltaPct, -0.05, "negative WoW сохраняется")
    }

    func testSlackBreakdownWowDeltaPctDefaultNil() {
        let bd = SlackActivityBreakdown(
            messagesCount: 10,
            huddleMinutes: 0,
            byChannel: []
        )
        XCTAssertNil(bd.wowDeltaPct)
    }

    func testSlackBreakdownWowDeltaPctExplicit() {
        let bd = SlackActivityBreakdown(
            messagesCount: 10,
            huddleMinutes: 0,
            byChannel: [],
            wowDeltaPct: 0.0
        )
        XCTAssertEqual(bd.wowDeltaPct, 0.0, "zero WoW (без change) — legitimate value, не nil")
    }

    // MARK: - Phase 4.6.C.3 — per-provider streaks в breakdown structs

    func testLinearBreakdownIssueCloseStreakDefaultNil() {
        let bd = LinearActivityBreakdown(
            issuesTouched: 3,
            byProject: [],
            byStatus: []
        )
        XCTAssertNil(bd.issueCloseStreak, "default nil — backwards compat")
    }

    func testLinearBreakdownIssueCloseStreakExplicit() {
        let bd = LinearActivityBreakdown(
            issuesTouched: 3,
            byProject: [],
            byStatus: [],
            issueCloseStreak: 5
        )
        XCTAssertEqual(bd.issueCloseStreak, 5)
    }

    func testGithubBreakdownCommitStreakDefaultNil() {
        let bd = GitHubActivityBreakdown(
            eventsCount: 5,
            byRepo: [],
            byEventKind: []
        )
        XCTAssertNil(bd.commitStreak)
    }

    func testGithubBreakdownCommitStreakExplicit() {
        let bd = GitHubActivityBreakdown(
            eventsCount: 5,
            byRepo: [],
            byEventKind: [],
            commitStreak: 12
        )
        XCTAssertEqual(bd.commitStreak, 12, "long streak (12 days) сохраняется")
    }

    func testSlackBreakdownHuddleParticipationStreakDefaultNil() {
        let bd = SlackActivityBreakdown(
            messagesCount: 10,
            huddleMinutes: 0,
            byChannel: []
        )
        XCTAssertNil(bd.huddleParticipationStreak)
    }

    func testSlackBreakdownHuddleParticipationStreakExplicit() {
        let bd = SlackActivityBreakdown(
            messagesCount: 10,
            huddleMinutes: 0,
            byChannel: [],
            huddleParticipationStreak: 1
        )
        XCTAssertEqual(bd.huddleParticipationStreak, 1,
            "single-day streak=1 — legitimate value (не nil), edge между \"never\" и \"started today\"")
    }
}
