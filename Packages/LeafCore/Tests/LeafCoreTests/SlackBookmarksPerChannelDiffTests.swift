//
//  SlackBookmarksPerChannelDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 Task 7 — pure diff helper tests for warm-tier
//  per-channel bookmarks diff (added / removed by id).
//

import XCTest

@testable import LeafCore

final class SlackBookmarksPerChannelDiffTests: XCTestCase {
    private func mk(
        _ channel: String, _ id: String, _ title: String = "t", _ link: String = "https://x", _ ts: Int64 = 1
    ) -> SlackBookmark {
        SlackBookmark(channelID: channel, id: id, title: title, link: link, lastEditedMs: ts)
    }

    func testBootstrapEmptyPriorNoEvents() {
        let prior: [SlackChannelBookmarksSnapshot] = []
        let curr = [
            SlackChannelBookmarksSnapshot(channelID: "C1", bookmarks: [mk("C1", "B1")])
        ]
        let (added, removed) = SlackWarmCollector.bookmarksPerChannelDiff(prior: prior, current: curr)
        XCTAssertEqual(added, [])
        XCTAssertEqual(removed, [])
    }

    func testAddedBookmarkDetected() {
        let prior = [
            SlackChannelBookmarksSnapshot(channelID: "C1", bookmarks: [mk("C1", "B1")])
        ]
        let curr = [
            SlackChannelBookmarksSnapshot(channelID: "C1", bookmarks: [mk("C1", "B1"), mk("C1", "B2", "new")])
        ]
        let (added, removed) = SlackWarmCollector.bookmarksPerChannelDiff(prior: prior, current: curr)
        XCTAssertEqual(added.map(\.id), ["B2"])
        XCTAssertEqual(removed, [])
    }

    func testRemovedBookmarkDetected() {
        let prior = [
            SlackChannelBookmarksSnapshot(channelID: "C1", bookmarks: [mk("C1", "B1"), mk("C1", "B2")])
        ]
        let curr = [
            SlackChannelBookmarksSnapshot(channelID: "C1", bookmarks: [mk("C1", "B1")])
        ]
        let (added, removed) = SlackWarmCollector.bookmarksPerChannelDiff(prior: prior, current: curr)
        XCTAssertEqual(added, [])
        XCTAssertEqual(removed.map(\.id), ["B2"])
    }

    func testNoChangeNoEvents() {
        let prior = [
            SlackChannelBookmarksSnapshot(channelID: "C1", bookmarks: [mk("C1", "B1")])
        ]
        let curr = [
            SlackChannelBookmarksSnapshot(channelID: "C1", bookmarks: [mk("C1", "B1")])
        ]
        let (added, removed) = SlackWarmCollector.bookmarksPerChannelDiff(prior: prior, current: curr)
        XCTAssertEqual(added, [])
        XCTAssertEqual(removed, [])
    }
}
