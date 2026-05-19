//
//  HomeRelativeTimeFormatterTests.swift
//  Phase 8.9 (P9) — C-22 unification of formatRelative across Home blocks.
//  Locks the bucket ladder contract: now / Nm ago / Nh ago / yesterday /
//  N days ago / absolute "MMM d" (en_US_POSIX cached).
//

import XCTest

@testable import LeafCore

final class HomeRelativeTimeFormatterTests: XCTestCase {
    /// 2026-05-19 00:00:00 UTC anchor. Picked so the "14 days ago" absolute
    /// case lands on a deterministic "May 5" string in en_US_POSIX.
    private let now: Int64 = 1_747_612_800_000

    func testNowBucket_underMinute() {
        XCTAssertEqual(HomeRelativeTimeFormatter.format(deltaMs: 30_000, nowMs: now), "now")
    }

    func testMinutesBucket() {
        XCTAssertEqual(HomeRelativeTimeFormatter.format(deltaMs: 5 * 60_000, nowMs: now), "5m ago")
    }

    func testHoursBucket() {
        XCTAssertEqual(HomeRelativeTimeFormatter.format(deltaMs: 3 * 3600 * 1000, nowMs: now), "3h ago")
    }

    func testYesterdayBucket_30hours() {
        XCTAssertEqual(HomeRelativeTimeFormatter.format(deltaMs: 30 * 3600 * 1000, nowMs: now), "yesterday")
    }

    func testDaysBucket_4days() {
        XCTAssertEqual(HomeRelativeTimeFormatter.format(deltaMs: 4 * 86_400 * 1000, nowMs: now), "4 days ago")
    }

    func testAbsoluteBucket_14days() {
        // 14 days before 2026-05-19 00:00 UTC = 2026-05-05 00:00 UTC
        let result = HomeRelativeTimeFormatter.format(deltaMs: 14 * 86_400 * 1000, nowMs: now)
        XCTAssertEqual(result, "May 5")
    }

    func testClockSkewGuard_negativeDelta() {
        XCTAssertEqual(HomeRelativeTimeFormatter.format(deltaMs: -500, nowMs: now), "now")
    }

    func testZeroDelta() {
        XCTAssertEqual(HomeRelativeTimeFormatter.format(deltaMs: 0, nowMs: now), "now")
    }
}
