// Phase 4.4 — minimal contract test для StubSlackAPIProvider.
// Prod parser (users.profile.get + search.messages mapping, DM anonymization,
// ADR-010 enforcement, ratelimited/401 paths) tested separately в
// LeafCorePrivateTests/ProdSlackAPIProviderTests.swift (moat, B5).

import XCTest
@testable import LeafCore

final class SlackAPIProviderTests: XCTestCase {
    func testStubReturnsEmpty() async throws {
        let provider = StubSlackAPIProvider()
        let result = try await provider.fetchTick(
            accessToken: "t",
            userID: "U123",
            since: nil,
            now: Date()
        )
        XCTAssertEqual(result, .empty)
        XCTAssertEqual(result.huddle, .unknown)
        XCTAssertTrue(result.channelMessageCounts.isEmpty)
        XCTAssertNil(result.cursorMs)
    }

    func testStubIgnoresSinceAndUserID() async throws {
        let provider = StubSlackAPIProvider()
        let result = try await provider.fetchTick(
            accessToken: "t",
            userID: "U999",
            since: 1_700_000_000_000,
            now: Date(timeIntervalSince1970: 1_700_000_500)
        )
        XCTAssertEqual(result, .empty)
    }

    func testHuddleStateForwardCompat() {
        XCTAssertEqual(SlackHuddleState(slackAPIString: "default_unset"), .defaultUnset)
        XCTAssertEqual(SlackHuddleState(slackAPIString: "in_a_huddle"), .inAHuddle)
        XCTAssertEqual(SlackHuddleState(slackAPIString: "unknown"), .unknown)
        // Будущий Slack state, которого мы ещё не знаем → fallback .unknown,
        // collector такие transitions не emit'ит.
        XCTAssertEqual(SlackHuddleState(slackAPIString: "in_a_meeting_v2"), .unknown)
        XCTAssertEqual(SlackHuddleState(slackAPIString: ""), .unknown)
    }

    func testHuddleStateRawValuesMatchSlackAPI() {
        // Sanity: rawValue идёт в DB через persistence layer (B6+) и в transition
        // emission. Любая случайная переименовка ломает forward-compat / DB rows.
        XCTAssertEqual(SlackHuddleState.defaultUnset.rawValue, "default_unset")
        XCTAssertEqual(SlackHuddleState.inAHuddle.rawValue, "in_a_huddle")
        XCTAssertEqual(SlackHuddleState.unknown.rawValue, "unknown")
    }
}
