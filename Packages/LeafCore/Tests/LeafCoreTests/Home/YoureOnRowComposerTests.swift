//
//  YoureOnRowComposerTests.swift
//  Track-10 T7 — pure-function row composition for YoureOnBlock. View body
//  ships untested (precedent: TodayBlock / ResumeHeroBlock / NeedsYouBlock /
//  SinceLastActiveBlock / TeamNBlock — no SwiftUI snapshot infra in the app
//  target). This suite locks the composition contract the SwiftUI body consumes.
//

import XCTest

@testable import LeafCore

final class YoureOnRowComposerTests: XCTestCase {

    // MARK: - composeTaskLine

    func testComposeTaskLine_allThreeComponents() {
        let identity = TaskIdentity(linearID: "GUN-50", branch: "feature/x")
        let delta = GitDeltaSnapshot(
            commitsAhead: 5, commitsBehind: 0, uncommittedCount: 0,
            mergeBase: "origin/main")
        XCTAssertEqual(
            YoureOnRowComposer.composeTaskLine(identity, gitDelta: delta),
            "GUN-50 · feature/x · +5 ahead of main")
    }

    func testComposeTaskLine_linearOnly() {
        let identity = TaskIdentity(linearID: "GUN-50")
        XCTAssertEqual(
            YoureOnRowComposer.composeTaskLine(identity, gitDelta: nil),
            "GUN-50")
    }

    func testComposeTaskLine_branchOnly() {
        let identity = TaskIdentity(branch: "feature/x")
        XCTAssertEqual(
            YoureOnRowComposer.composeTaskLine(identity, gitDelta: nil),
            "feature/x")
    }

    /// `commitsAhead == 0` → suppress "+N ahead" suffix to avoid noisy
    /// "GUN-50 · +0 ahead of main" rendering on a freshly-rebased branch.
    func testComposeTaskLine_aheadZero_suppressesAheadSuffix() {
        let identity = TaskIdentity(linearID: "GUN-50")
        let delta = GitDeltaSnapshot(
            commitsAhead: 0, commitsBehind: 0, uncommittedCount: 0,
            mergeBase: "origin/main")
        XCTAssertEqual(
            YoureOnRowComposer.composeTaskLine(identity, gitDelta: delta),
            "GUN-50")
    }

    func testComposeTaskLine_allNil_returnsNil() {
        let identity = TaskIdentity()
        XCTAssertNil(YoureOnRowComposer.composeTaskLine(identity, gitDelta: nil))
    }

    // MARK: - composeSessionLine

    func testComposeSessionLine_startAndFocused() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // 1_716_454_680_000 ms = 2024-05-23 09:18:00 UTC
        let startMs: Int64 = 1_716_454_680_000
        let now = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000 + 92 * 60)
        let line = YoureOnRowComposer.composeSessionLine(
            sessionStartMs: startMs, focusedMin: 92, now: now, calendar: cal)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("Started"))
        XCTAssertTrue(line!.contains("1h 32m"))
        XCTAssertTrue(line!.contains("focused so far"))
    }

    func testComposeSessionLine_returnsNil_whenStartMsIsZero() {
        let line = YoureOnRowComposer.composeSessionLine(
            sessionStartMs: 0, focusedMin: 92, now: Date(), calendar: .current)
        XCTAssertNil(line)
    }

    /// Drops "focused so far" suffix when focusedMin == 0 (cold session right
    /// after sessionStart, or the fallback-to-midnight path with no IDE bundle).
    func testComposeSessionLine_focusedZero_dropsSuffix() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let line = YoureOnRowComposer.composeSessionLine(
            sessionStartMs: 1_716_454_680_000, focusedMin: 0,
            now: Date(), calendar: cal)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("Started"))
        XCTAssertFalse(line!.contains("focused so far"))
    }

    // MARK: - composeFilesLine

    func testComposeFilesLine_empty_returnsNil() {
        XCTAssertNil(YoureOnRowComposer.composeFilesLine([]))
    }

    func testComposeFilesLine_oneFile() {
        XCTAssertEqual(
            YoureOnRowComposer.composeFilesLine(["A.swift"]),
            "Open files: A.swift")
    }

    func testComposeFilesLine_threeFiles_dotSeparator() {
        XCTAssertEqual(
            YoureOnRowComposer.composeFilesLine(["A.swift", "B.swift", "C.swift"]),
            "Open files: A.swift · B.swift · C.swift")
    }

    // MARK: - formatFocusedMin

    func testFormatFocusedMin_lessThanHour() {
        XCTAssertEqual(YoureOnRowComposer.formatFocusedMin(45), "45m")
    }

    func testFormatFocusedMin_oneHourPlusMin() {
        XCTAssertEqual(YoureOnRowComposer.formatFocusedMin(92), "1h 32m")
    }

    func testFormatFocusedMin_exactHour() {
        XCTAssertEqual(YoureOnRowComposer.formatFocusedMin(60), "1h 0m")
    }

    func testFormatFocusedMin_zero_returnsEmptyString() {
        XCTAssertEqual(YoureOnRowComposer.formatFocusedMin(0), "")
    }

    // MARK: - formatSessionStart

    func testFormatSessionStart_HHMM_UTC() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // 1_716_454_680_000 ms = 2024-05-23 09:18:00 UTC
        let startMs: Int64 = 1_716_454_680_000
        XCTAssertEqual(
            YoureOnRowComposer.formatSessionStart(startMs, calendar: cal),
            "08:58")
    }

    // MARK: - refBasename

    func testRefBasename_stripsToLastSegment() {
        XCTAssertEqual(YoureOnRowComposer.refBasename("origin/main"), "main")
        XCTAssertEqual(YoureOnRowComposer.refBasename("main"), "main")
        XCTAssertEqual(
            YoureOnRowComposer.refBasename("refs/remotes/origin/develop"),
            "develop")
    }

    // MARK: - a11yLabel

    /// Composes all three lines (task / session / files) into a comma-separated
    /// VoiceOver label with `· → ,` translation per Track-10 §9.1 C-39 a11y
    /// readability discipline.
    func testA11yLabel_composesAllLines() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let identity = TaskIdentity(linearID: "GUN-50", branch: "feature/x")
        let delta = GitDeltaSnapshot(
            commitsAhead: 5, commitsBehind: 0, uncommittedCount: 0,
            mergeBase: "origin/main")
        let label = YoureOnRowComposer.a11yLabel(
            identity, gitDelta: delta,
            sessionStartMs: 1_716_454_680_000, focusedMin: 92,
            openFiles: ["A.swift"],
            now: Date(timeIntervalSince1970: TimeInterval(1_716_454_680_000) / 1000 + 92 * 60),
            calendar: cal)
        XCTAssertTrue(label.contains("Working on GUN-50, feature/x, +5 ahead of main"))
        XCTAssertTrue(label.contains("Started 08:58"))
        XCTAssertTrue(label.contains("1h 32m focused so far"))
        XCTAssertTrue(label.contains("Open files: A.swift"))
        // Dot-separator translated to comma.
        XCTAssertFalse(label.contains(" · "))
    }
}
