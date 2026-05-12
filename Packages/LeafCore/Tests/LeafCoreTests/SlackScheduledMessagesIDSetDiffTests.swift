//
//  SlackScheduledMessagesIDSetDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 Task 7 — pure diff helper tests for warm-tier
//  scheduled messages diff (scheduled / sent transitions).
//

import XCTest
@testable import LeafCore

final class SlackScheduledMessagesIDSetDiffTests: XCTestCase {
    func testBootstrapEmptyPriorNoEvents() {
        let prior = SlackScheduledMessagesSnapshot.empty
        let curr = SlackScheduledMessagesSnapshot(messages: [
            SlackScheduledMessage(id: "M1", channelID: "C1", scheduledFor: 1000, sent: false)
        ])
        let (scheduled, sent) = SlackWarmCollector.scheduledMessagesDiff(prior: prior, current: curr)
        XCTAssertEqual(scheduled, [])
        XCTAssertEqual(sent, [])
    }

    func testNewScheduledMessage() {
        let prior = SlackScheduledMessagesSnapshot(messages: [
            SlackScheduledMessage(id: "M1", channelID: "C1", scheduledFor: 1000, sent: false)
        ])
        let curr = SlackScheduledMessagesSnapshot(messages: [
            SlackScheduledMessage(id: "M1", channelID: "C1", scheduledFor: 1000, sent: false),
            SlackScheduledMessage(id: "M2", channelID: "C2", scheduledFor: 2000, sent: false)
        ])
        let (scheduled, sent) = SlackWarmCollector.scheduledMessagesDiff(prior: prior, current: curr)
        XCTAssertEqual(scheduled.map(\.id), ["M2"])
        XCTAssertEqual(sent, [])
    }

    func testSentTransitionFalseToTrue() {
        let prior = SlackScheduledMessagesSnapshot(messages: [
            SlackScheduledMessage(id: "M1", channelID: "C1", scheduledFor: 1000, sent: false)
        ])
        let curr = SlackScheduledMessagesSnapshot(messages: [
            SlackScheduledMessage(id: "M1", channelID: "C1", scheduledFor: 1000, sent: true)
        ])
        let (scheduled, sent) = SlackWarmCollector.scheduledMessagesDiff(prior: prior, current: curr)
        XCTAssertEqual(scheduled, [])
        XCTAssertEqual(sent.map(\.id), ["M1"])
        XCTAssertEqual(sent.first?.sent, true)
    }

    func testSentInferredFromDisappearance() {
        // Slack drops sent messages from the scheduled list — id missing in current
        // (but was unsent in prior) is treated as sent.
        let prior = SlackScheduledMessagesSnapshot(messages: [
            SlackScheduledMessage(id: "M1", channelID: "C1", scheduledFor: 1000, sent: false)
        ])
        let curr = SlackScheduledMessagesSnapshot.empty
        let (scheduled, sent) = SlackWarmCollector.scheduledMessagesDiff(prior: prior, current: curr)
        // Bootstrap-empty current is ambiguous, but empty-prior is bootstrap; non-empty prior + empty current treats prior as sent.
        XCTAssertEqual(scheduled, [])
        XCTAssertEqual(sent.map(\.id), ["M1"])
    }

    func testNoChangeNoEvents() {
        let prior = SlackScheduledMessagesSnapshot(messages: [
            SlackScheduledMessage(id: "M1", channelID: "C1", scheduledFor: 1000, sent: false)
        ])
        let curr = SlackScheduledMessagesSnapshot(messages: [
            SlackScheduledMessage(id: "M1", channelID: "C1", scheduledFor: 1000, sent: false)
        ])
        let (scheduled, sent) = SlackWarmCollector.scheduledMessagesDiff(prior: prior, current: curr)
        XCTAssertEqual(scheduled, [])
        XCTAssertEqual(sent, [])
    }
}
