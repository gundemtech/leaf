import XCTest

@testable import LeafCore

/// Settings dead-toggle remediation (WS2) — pure decision matrix for foreground
/// notification presentation. The app's willPresent maps the result to
/// UNNotificationPresentationOptions; this fn holds the testable logic.
/// Defaults (respectFocus/sound/coalesce) are ON, matching the pref-store
/// fallback; the matrix pins the default-ON behavior deliberately.
final class NotificationPresentationDeciderTests: XCTestCase {

    private func decide(
        sound: Bool = true, respectFocus: Bool = true, inFocus: Bool = false,
        coalesce: Bool = true, recent: [Int64] = [], nowMs: Int64 = 1_000_000
    ) -> NotificationPresentation {
        NotificationPresentationDecider.decide(
            soundEnabled: sound, respectFocus: respectFocus, inFocus: inFocus,
            coalesceEnabled: coalesce, recentPresentationsMs: recent, nowMs: nowMs)
    }

    func test_default_allOptionsWhenNotFocusedNoBurst() {
        XCTAssertEqual(decide(), NotificationPresentation(banner: true, sound: true, badge: true))
    }

    func test_soundOff_dropsSoundKeepsBannerAndBadge() {
        let p = decide(sound: false)
        XCTAssertFalse(p.sound)
        XCTAssertTrue(p.banner)
        XCTAssertTrue(p.badge)
    }

    func test_respectFocusAndInFocus_badgeOnly() {
        XCTAssertEqual(
            decide(respectFocus: true, inFocus: true),
            NotificationPresentation(banner: false, sound: false, badge: true))
    }

    func test_inFocusButRespectFocusOff_stillShows() {
        let p = decide(respectFocus: false, inFocus: true)
        XCTAssertTrue(p.banner)
        XCTAssertTrue(p.sound)
    }

    func test_coalesce_suppressesWhenThreeOrMoreInWindow() {
        let now: Int64 = 1_000_000
        let recent: [Int64] = [now - 1_000, now - 2_000, now - 3_000]
        XCTAssertEqual(
            decide(coalesce: true, recent: recent, nowMs: now),
            NotificationPresentation(banner: false, sound: false, badge: true))
    }

    func test_coalesce_belowThresholdShows() {
        let now: Int64 = 1_000_000
        XCTAssertTrue(decide(coalesce: true, recent: [now - 1_000, now - 2_000], nowMs: now).banner)
    }

    func test_coalesce_presentationsOutside5minWindowIgnored() {
        let now: Int64 = 10_000_000
        let stale: [Int64] = [now - 6 * 60_000, now - 7 * 60_000, now - 8 * 60_000]
        XCTAssertTrue(decide(coalesce: true, recent: stale, nowMs: now).banner)
    }

    func test_coalesceDisabled_ignoresBurst() {
        let now: Int64 = 1_000_000
        let burst: [Int64] = [now - 1, now - 2, now - 3, now - 4]
        XCTAssertTrue(decide(coalesce: false, recent: burst, nowMs: now).banner)
    }

    func test_badgeAlwaysOn() {
        XCTAssertTrue(decide(respectFocus: true, inFocus: true, coalesce: true,
            recent: [0, 0, 0]).badge)
    }
}
