//
//  SlackUserConversationsDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 Task 7 — pure diff helper tests for warm-tier
//  user_conversations top-10 ranking + joined/left detection.
//

import XCTest

@testable import LeafCore

final class SlackUserConversationsDiffTests: XCTestCase {
    func testBootstrapEmitsNothing() {
        let curr = SlackMemberChannelsTopList(channels: [
            SlackMemberChannel(id: "C1", name: "general", latestTs: 1000)
        ])
        let events = SlackWarmCollector.userConversationsDiff(prior: nil, current: curr)
        XCTAssertEqual(events.joined, [])
        XCTAssertEqual(events.left, [])
    }

    func testJoinedChannelDetected() {
        let prior = SlackMemberChannelsTopList(channels: [
            SlackMemberChannel(id: "C1", name: "general", latestTs: 1000)
        ])
        let curr = SlackMemberChannelsTopList(channels: [
            SlackMemberChannel(id: "C1", name: "general", latestTs: 1000),
            SlackMemberChannel(id: "C2", name: "random", latestTs: 1500),
        ])
        let events = SlackWarmCollector.userConversationsDiff(prior: prior, current: curr)
        XCTAssertEqual(events.joined.map(\.id), ["C2"])
        XCTAssertEqual(events.left, [])
    }

    func testLeftChannelDetected() {
        let prior = SlackMemberChannelsTopList(channels: [
            SlackMemberChannel(id: "C1", name: "general", latestTs: 1000),
            SlackMemberChannel(id: "C2", name: "random", latestTs: 1500),
        ])
        let curr = SlackMemberChannelsTopList(channels: [
            SlackMemberChannel(id: "C1", name: "general", latestTs: 1000)
        ])
        let events = SlackWarmCollector.userConversationsDiff(prior: prior, current: curr)
        XCTAssertEqual(events.joined, [])
        XCTAssertEqual(events.left.map(\.id), ["C2"])
    }

    func testRanksByLatestTsDesc() {
        let raw = [
            SlackMemberChannel(id: "C1", name: "general", latestTs: 1000),
            SlackMemberChannel(id: "C2", name: "random", latestTs: 3000),
            SlackMemberChannel(id: "C3", name: "alerts", latestTs: 2000),
            SlackMemberChannel(id: "C4", name: "empty", latestTs: nil),
        ]
        let top10 = SlackWarmCollector.rankTop10ByLatestTs(from: raw)
        XCTAssertEqual(top10.channels.map(\.id), ["C2", "C3", "C1", "C4"])
    }

    func testTop10Cap() {
        let raw = (1...15).map { i in
            SlackMemberChannel(id: "C\(i)", name: "ch\(i)", latestTs: Int64(i * 100))
        }
        let top10 = SlackWarmCollector.rankTop10ByLatestTs(from: raw)
        XCTAssertEqual(top10.channels.count, 10)
        XCTAssertEqual(top10.channels.first?.id, "C15")
        XCTAssertEqual(top10.channels.last?.id, "C6")
    }
}
