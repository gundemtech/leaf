// Packages/LeafCore/Tests/LeafCoreTests/BrowserBookmarksWatcherTests.swift
import XCTest
@testable import LeafCore

// MARK: - Mock

final class MockBookmarkWriter: BookmarkEventBatchWriter, @unchecked Sendable {
    private(set) var events: [RawEvent] = []

    func write(_ events: [RawEvent]) throws {
        self.events.append(contentsOf: events)
    }
}

// MARK: - Tests

final class BrowserBookmarksWatcherTests: XCTestCase {

    func testColdTickNoEmit() async throws {
        let writer = MockBookmarkWriter()
        let watcher = BrowserBookmarksWatcher(
            writer: writer,
            chromeCountProbe: { _ in 42 },
            safariCountProbe: { _ in 12 },
            fdaGranted: true
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
            fdaGranted: true
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
            fdaGranted: true
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
            fdaGranted: false
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
            fdaGranted: true
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
            fdaGranted: true
        )
        await watcher.handleChromeEvent(profileLabel: "Default", nowMs: 1000)
        await watcher.handleChromeEvent(profileLabel: "Default", nowMs: 2000)
        XCTAssertEqual(writer.events.count, 1)
        XCTAssertEqual(writer.events[0].payload["delta"], "0")
    }
}
