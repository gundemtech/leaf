// SlackHeadlineFormatterTests.swift
import XCTest
@testable import LeafCore

final class SlackHeadlineFormatterTests: XCTestCase {
    func test_zeroMessages_pluralized() {
        let h = SlackHeadlineFormatter.headline(breakdown: .empty, range: .week)
        XCTAssertEqual(h.value, "0 messages")
    }

    func test_singleMessage_singular() {
        let b = SlackActivityBreakdown(
            messagesCount: 1, huddleMinutes: 0, byChannel: [],
            reactionsReceived: nil, huddleSessionStats: nil, wowDeltaPct: nil,
            huddleParticipationStreak: nil
        )
        XCTAssertEqual(SlackHeadlineFormatter.headline(breakdown: b, range: .week).value, "1 message")
    }

    func test_huddleMinutesAppearInTrend() {
        let b = SlackActivityBreakdown(
            messagesCount: 112, huddleMinutes: 65, byChannel: [],
            reactionsReceived: nil, huddleSessionStats: nil, wowDeltaPct: nil,
            huddleParticipationStreak: nil
        )
        let h = SlackHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertNotNil(h.trend)
        XCTAssertTrue(h.trend!.contains("65m huddle") || h.trend!.contains("65 min huddle"))
    }

    func test_zeroHuddle_omittedFromTrend() {
        let b = SlackActivityBreakdown(
            messagesCount: 50, huddleMinutes: 0, byChannel: [],
            reactionsReceived: nil, huddleSessionStats: nil, wowDeltaPct: 0.1,
            huddleParticipationStreak: nil
        )
        let h = SlackHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertFalse(h.trend!.contains("huddle"))
    }

    func test_huddleStreakAppearsInTrend() {
        let b = SlackActivityBreakdown(
            messagesCount: 10, huddleMinutes: 30, byChannel: [],
            reactionsReceived: nil, huddleSessionStats: nil, wowDeltaPct: nil,
            huddleParticipationStreak: 3
        )
        let h = SlackHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertTrue(h.trend!.contains("3-day"))
    }

    func test_wowDelta_renderedInTrend() {
        let b = SlackActivityBreakdown(
            messagesCount: 50, huddleMinutes: 0, byChannel: [],
            reactionsReceived: nil, huddleSessionStats: nil, wowDeltaPct: 0.2,
            huddleParticipationStreak: nil
        )
        let h = SlackHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertTrue(h.trend!.contains("+20%"))
    }

    func test_noWowNoHuddleNoStreak_trendNil() {
        let b = SlackActivityBreakdown(
            messagesCount: 50, huddleMinutes: 0, byChannel: [],
            reactionsReceived: nil, huddleSessionStats: nil, wowDeltaPct: nil,
            huddleParticipationStreak: nil
        )
        XCTAssertNil(SlackHeadlineFormatter.headline(breakdown: b, range: .week).trend)
    }

    func test_allThree_combined() {
        let b = SlackActivityBreakdown(
            messagesCount: 112, huddleMinutes: 65, byChannel: [],
            reactionsReceived: nil, huddleSessionStats: nil, wowDeltaPct: 0.15,
            huddleParticipationStreak: 4
        )
        let h = SlackHeadlineFormatter.headline(breakdown: b, range: .week)
        let count = h.trend!.components(separatedBy: " · ").count
        XCTAssertEqual(count, 3, "expected 3 trend parts, got: \(h.trend!)")
    }

    func test_negativeWow() {
        let b = SlackActivityBreakdown(
            messagesCount: 10, huddleMinutes: 0, byChannel: [],
            reactionsReceived: nil, huddleSessionStats: nil, wowDeltaPct: -0.15,
            huddleParticipationStreak: nil
        )
        let h = SlackHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertTrue(h.trend!.contains("−15%") || h.trend!.contains("-15%"))
    }

    func test_oneDayStreak_singular() {
        let b = SlackActivityBreakdown(
            messagesCount: 5, huddleMinutes: 0, byChannel: [],
            reactionsReceived: nil, huddleSessionStats: nil, wowDeltaPct: nil,
            huddleParticipationStreak: 1
        )
        let h = SlackHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertTrue(h.trend!.contains("1-day"))
    }
}
