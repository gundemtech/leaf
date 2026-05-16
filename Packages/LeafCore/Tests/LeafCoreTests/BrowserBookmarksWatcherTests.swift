// Packages/LeafCore/Tests/LeafCoreTests/BrowserBookmarksWatcherTests.swift
import XCTest
@testable import LeafCore

// MARK: - Mocks / helpers

final class MockBookmarkWriter: BookmarkEventBatchWriter, @unchecked Sendable {
    private(set) var events: [RawEvent] = []

    func write(_ events: [RawEvent]) throws {
        self.events.append(contentsOf: events)
    }
}

/// Feature gate that enables both Chrome and Safari — used by all existing tests
/// that don't specifically test toggle gating.
struct AlwaysOnFeatureGate: BrowserBookmarksFeatureGate {
    var chromeEnabled: Bool { true }
    var safariEnabled: Bool { true }
}

/// Feature gate with configurable per-browser flags — used by toggle-gating tests.
struct ConfigurableFeatureGate: BrowserBookmarksFeatureGate {
    var chromeEnabled: Bool
    var safariEnabled: Bool
}

// MARK: - Tests

final class BrowserBookmarksWatcherTests: XCTestCase {

    func testColdTickNoEmit() async throws {
        let writer = MockBookmarkWriter()
        let watcher = BrowserBookmarksWatcher(
            writer: writer,
            chromeCountProbe: { _ in 42 },
            safariCountProbe: { _ in 12 },
            fdaGranted: true,
            featureGate: AlwaysOnFeatureGate()
        )
        // simulate first FSEvent on Chrome path — seeds the counter, no emit
        await watcher.handleChromeEvent(profileLabel: "Default", nowMs: 1000)
        XCTAssertEqual(writer.events.count, 0, "cold tick seeds, no emit")
    }

    func testWarmTickEmitsOnCountDelta() async throws {
        let writer = MockBookmarkWriter()
        nonisolated(unsafe) var chromeCount = 42
        let watcher = BrowserBookmarksWatcher(
            writer: writer,
            chromeCountProbe: { _ in chromeCount },
            safariCountProbe: { _ in 12 },
            fdaGranted: true,
            featureGate: AlwaysOnFeatureGate()
        )
        await watcher.handleChromeEvent(profileLabel: "Default", nowMs: 1000)
        chromeCount = 43
        await watcher.handleChromeEvent(profileLabel: "Default", nowMs: 2000)
        XCTAssertEqual(writer.events.count, 1)
        XCTAssertEqual(writer.events[0].payload["event_kind"], "chrome_bookmark_changed")
        XCTAssertEqual(writer.events[0].payload["delta"], "1")
        XCTAssertEqual(writer.events[0].payload["total_count"], "43")
        XCTAssertEqual(writer.events[0].payload["profile_label"], "Default")
    }

    func testChromeMultiProfileSeparateCounters() async throws {
        let writer = MockBookmarkWriter()
        nonisolated(unsafe) var counts: [String: Int] = ["Default": 10, "Profile 1": 5]
        let watcher = BrowserBookmarksWatcher(
            writer: writer,
            chromeCountProbe: { p in counts[p] ?? 0 },
            safariCountProbe: { _ in 0 },
            fdaGranted: true,
            featureGate: AlwaysOnFeatureGate()
        )
        await watcher.handleChromeEvent(profileLabel: "Default", nowMs: 1000)
        await watcher.handleChromeEvent(profileLabel: "Profile 1", nowMs: 1000)
        counts["Profile 1"] = 6
        await watcher.handleChromeEvent(profileLabel: "Profile 1", nowMs: 2000)
        XCTAssertEqual(writer.events.count, 1)
        XCTAssertEqual(writer.events[0].payload["profile_label"], "Profile 1")
        XCTAssertEqual(writer.events[0].payload["delta"], "1")
    }

    func testSafariFDADeniedNoEmit() async throws {
        let writer = MockBookmarkWriter()
        let watcher = BrowserBookmarksWatcher(
            writer: writer,
            chromeCountProbe: { _ in 0 },
            safariCountProbe: { _ in 12 },
            fdaGranted: false,
            featureGate: AlwaysOnFeatureGate()
        )
        await watcher.handleSafariEvent(nowMs: 1000)
        await watcher.handleSafariEvent(nowMs: 2000)
        XCTAssertEqual(writer.events.count, 0, "FDA denied — Safari watcher skips")
    }

    func testSafariDeltaEmits() async throws {
        let writer = MockBookmarkWriter()
        nonisolated(unsafe) var safari = 12
        let watcher = BrowserBookmarksWatcher(
            writer: writer,
            chromeCountProbe: { _ in 0 },
            safariCountProbe: { _ in safari },
            fdaGranted: true,
            featureGate: AlwaysOnFeatureGate()
        )
        await watcher.handleSafariEvent(nowMs: 1000)
        safari = 11
        await watcher.handleSafariEvent(nowMs: 2000)
        XCTAssertEqual(writer.events.count, 1)
        XCTAssertEqual(writer.events[0].payload["event_kind"], "safari_bookmark_changed")
        XCTAssertEqual(writer.events[0].payload["delta"], "-1")
        XCTAssertNil(writer.events[0].payload["profile_label"], "Safari omits profile")
    }

    func testZeroDeltaStillEmits() async throws {
        // Bookmark renamed → count unchanged but signal still useful.
        let writer = MockBookmarkWriter()
        let watcher = BrowserBookmarksWatcher(
            writer: writer,
            chromeCountProbe: { _ in 42 },
            safariCountProbe: { _ in 0 },
            fdaGranted: true,
            featureGate: AlwaysOnFeatureGate()
        )
        await watcher.handleChromeEvent(profileLabel: "Default", nowMs: 1000)
        await watcher.handleChromeEvent(profileLabel: "Default", nowMs: 2000)
        XCTAssertEqual(writer.events.count, 1)
        XCTAssertEqual(writer.events[0].payload["delta"], "0")
    }

    // MARK: - MAJOR-2 toggle-gating tests

    func testChromeDisabledDoesNotEmit() async throws {
        // Gate with chromeEnabled=false — even a warm tick must not emit.
        let writer = MockBookmarkWriter()
        nonisolated(unsafe) var count = 42
        let watcher = BrowserBookmarksWatcher(
            writer: writer,
            chromeCountProbe: { _ in count },
            safariCountProbe: { _ in 0 },
            fdaGranted: true,
            featureGate: ConfigurableFeatureGate(chromeEnabled: false, safariEnabled: false)
        )
        await watcher.handleChromeEvent(profileLabel: "Default", nowMs: 1000)
        count = 43
        await watcher.handleChromeEvent(profileLabel: "Default", nowMs: 2000)
        XCTAssertEqual(writer.events.count, 0, "Chrome toggle OFF — no events emitted")
    }

    func testSafariDisabledDoesNotEmit() async throws {
        // Gate with safariEnabled=false — even a warm tick must not emit.
        let writer = MockBookmarkWriter()
        nonisolated(unsafe) var count = 12
        let watcher = BrowserBookmarksWatcher(
            writer: writer,
            chromeCountProbe: { _ in 0 },
            safariCountProbe: { _ in count },
            fdaGranted: true,
            featureGate: ConfigurableFeatureGate(chromeEnabled: false, safariEnabled: false)
        )
        await watcher.handleSafariEvent(nowMs: 1000)
        count = 11
        await watcher.handleSafariEvent(nowMs: 2000)
        XCTAssertEqual(writer.events.count, 0, "Safari toggle OFF — no events emitted")
    }

    // MARK: - MINOR-3 backup-file sanity test

    func testChromeRealBookmarksFileEmitsDelta() async throws {
        // Sanity marker: the FSEventStream callback only fires for paths ending
        // in "/Bookmarks" (not "/Bookmarks.bak" or "/Bookmarks.tmp"). This test
        // exercises the handleChromeEvent path directly to confirm the watcher
        // correctly emits exactly one delta event on count change.
        // The suffix filter lives in the FSEventStream closure (`.hasSuffix("/Bookmarks")`),
        // which already rejects ".bak" / ".tmp" — this test locks the handler contract.
        let writer = MockBookmarkWriter()
        nonisolated(unsafe) var count = 42
        let watcher = BrowserBookmarksWatcher(
            writer: writer,
            chromeCountProbe: { _ in count },
            safariCountProbe: { _ in 0 },
            fdaGranted: true,
            featureGate: AlwaysOnFeatureGate()
        )
        await watcher.handleChromeEvent(profileLabel: "Default", nowMs: 1000)
        count = 43
        await watcher.handleChromeEvent(profileLabel: "Default", nowMs: 2000)
        XCTAssertEqual(writer.events.count, 1, "real Bookmarks event emits exactly one delta")
    }
}
