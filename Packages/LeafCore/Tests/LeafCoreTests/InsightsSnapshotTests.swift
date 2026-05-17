import XCTest
@testable import LeafCore

/// Phase 2.5 — закрепляем семантику `InsightsSnapshot.isEmpty`. Это
/// load-bearing property: `InsightsReader` решает по нему `.loaded` vs
/// `.empty` в UI state machine. Любое новое поле snapshot'а должно быть
/// учтено в `isEmpty` — иначе ненулевое поле "проглотится" глобальным
/// "Collecting…" placeholder'ом.
///
/// Per-provider round-trip tests, breakdown wow/streak defaults, Linear
/// status-transitions, longestUninterruptedWindow, and Track 7 P2 surface
/// defaults are exercised in companion files:
///   - InsightsSnapshotProviderTests.swift
///   - InsightsSnapshotBreakdownTests.swift
///   - InsightsSnapshotTransitionsAndTrack7Tests.swift
final class InsightsSnapshotTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func emptySnapshot() -> InsightsSnapshot {
        InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500
        )
    }

    func testEmptyWhenAllFieldsZero() {
        XCTAssertTrue(emptySnapshot().isEmpty)
    }

    func testNotEmptyWhenTopAppsPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [
                AppTimeEntry(bundleID: "com.apple.dt.Xcode", duration: 600, firstSeen: now, lastSeen: now)
            ],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenSessionsPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [
                FocusSession(bundleID: "com.apple.dt.Xcode", start: now, end: now.addingTimeInterval(900))
            ],
            switchRate: 0,
            deepSessionMinSec: 1500
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenAIRatioPositive() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            aiRatio: 0.05,
            aiActiveSeconds: 300
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenStreakDaysPositive() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            deepWorkStreak: DeepWorkStreak(days: 1, totalSeconds: 1500)
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenFilesTouchedPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            filesTouched: ["~/Desktop/LeafControl/Leaf/LeafApp.swift"]
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenPeakHourPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            peakProductivityHour: 14
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenWeekOverWeekDeltaPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            weekOverWeekDelta: -0.10
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenActiveDaysInRowPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            activeDaysInRow: 3
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenSwitchRatePositive() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 4.2,
            deepSessionMinSec: 1500
        )
        XCTAssertFalse(snapshot.isEmpty)
    }
}
