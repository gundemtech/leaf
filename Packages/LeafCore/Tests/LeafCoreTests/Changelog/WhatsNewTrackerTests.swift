import XCTest

@testable import LeafCore

/// Phase 3 — decides when to auto-present the in-app What's New sheet. Rules:
/// onboarding must be complete; a clean install (no last-seen version) is seeded
/// SILENTLY (never shows notes on first launch); thereafter it presents only when
/// the running build is strictly newer than the last-seen version.
@MainActor
final class WhatsNewTrackerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "whatsNewTracker.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        super.tearDown()
    }

    private func tracker() -> WhatsNewTracker { WhatsNewTracker(defaults: defaults) }

    func test_firstLaunch_silentlySeeds_neverPresents() {
        let t = tracker()
        XCTAssertNil(t.lastSeenVersion)
        let present = t.shouldPresent(current: "1.0.0-alpha.30", hasCompletedOnboarding: true)
        XCTAssertFalse(present)                                  // clean install → no notes
        XCTAssertEqual(t.lastSeenVersion, "1.0.0-alpha.30")     // but seeded for next time
    }

    func test_onboardingIncomplete_neverPresents_andDoesNotSeed() {
        let t = tracker()
        let present = t.shouldPresent(current: "1.0.0-alpha.30", hasCompletedOnboarding: false)
        XCTAssertFalse(present)
        XCTAssertNil(t.lastSeenVersion)                         // not seeded until onboarding done
    }

    func test_upgrade_presents_andDoesNotAutoAdvance() {
        let t = tracker()
        t.markSeen("1.0.0-alpha.29")
        let present = t.shouldPresent(current: "1.0.0-alpha.30", hasCompletedOnboarding: true)
        XCTAssertTrue(present)
        // shouldPresent must NOT advance the cursor — the UI marks it seen only after
        // the sheet is actually shown (so a closed window doesn't lose the present).
        XCTAssertEqual(t.lastSeenVersion, "1.0.0-alpha.29")
    }

    func test_numericUpgrade_9_to_28_presents() {
        // The regression a string compare would miss (alpha.9 > alpha.28 lexically).
        let t = tracker()
        t.markSeen("1.0.0-alpha.9")
        XCTAssertTrue(t.shouldPresent(current: "1.0.0-alpha.28", hasCompletedOnboarding: true))
    }

    func test_sameVersion_doesNotPresent() {
        let t = tracker()
        t.markSeen("1.0.0-alpha.30")
        XCTAssertFalse(t.shouldPresent(current: "1.0.0-alpha.30", hasCompletedOnboarding: true))
    }

    func test_downgrade_doesNotPresent() {
        let t = tracker()
        t.markSeen("1.0.0-alpha.30")
        XCTAssertFalse(t.shouldPresent(current: "1.0.0-alpha.29", hasCompletedOnboarding: true))
    }

    func test_unparseableVersion_doesNotPresent() {
        let t = tracker()
        t.markSeen("1.0.0-alpha.29")
        XCTAssertFalse(t.shouldPresent(current: "garbage", hasCompletedOnboarding: true))
    }

    func test_markSeen_persistsAcrossInstances() {
        tracker().markSeen("1.0.0-alpha.31")
        XCTAssertEqual(tracker().lastSeenVersion, "1.0.0-alpha.31")
    }
}
