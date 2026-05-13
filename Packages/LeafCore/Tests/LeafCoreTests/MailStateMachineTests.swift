import XCTest
@testable import LeafCore

final class MailStateMachineTests: XCTestCase {
    func testSubFieldOptInGatesFirstEmission() {
        var sm = MailStateMachine()
        let events = sm.observe(MailObservation(activeMailboxName: "Inbox"), nowMs: 1000, mailboxNameOptedIn: false)
        XCTAssertEqual(events.count, 0)
    }

    func testWithOptInFirstObservationEmits() {
        var sm = MailStateMachine()
        let events = sm.observe(MailObservation(activeMailboxName: "Inbox"), nowMs: 1000, mailboxNameOptedIn: true)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "mail_active_mailbox_changed")
        XCTAssertEqual(events[0].payload["mailbox_name"], "Inbox")
    }

    func testIdempotentEmitsNothing() {
        var sm = MailStateMachine()
        let obs = MailObservation(activeMailboxName: "Inbox")
        _ = sm.observe(obs, nowMs: 1000, mailboxNameOptedIn: true)
        XCTAssertEqual(sm.observe(obs, nowMs: 2000, mailboxNameOptedIn: true).count, 0)
    }

    func testMailboxChangeEmitsWithOptIn() {
        var sm = MailStateMachine()
        _ = sm.observe(MailObservation(activeMailboxName: "Inbox"), nowMs: 1000, mailboxNameOptedIn: true)
        let events = sm.observe(MailObservation(activeMailboxName: "Sent"), nowMs: 2000, mailboxNameOptedIn: true)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["mailbox_name"], "Sent")
    }

    func testOptOutAdvancesPrevButEmitsNothing() {
        // While opted-out, sub-field is silent. Once user opts back in, only
        // a NEW transition should emit (we don't replay stale state).
        var sm = MailStateMachine()
        _ = sm.observe(MailObservation(activeMailboxName: "Inbox"), nowMs: 1000, mailboxNameOptedIn: false)
        let events = sm.observe(MailObservation(activeMailboxName: "Inbox"), nowMs: 2000, mailboxNameOptedIn: true)
        XCTAssertEqual(events.count, 0)
    }

    func testPayloadHasNoBodyOrSubjectOrSenderFields() {
        var sm = MailStateMachine()
        let events = sm.observe(MailObservation(activeMailboxName: "Inbox"), nowMs: 1000, mailboxNameOptedIn: true)
        XCTAssertNil(events[0].payload["body"])
        XCTAssertNil(events[0].payload["subject"])
        XCTAssertNil(events[0].payload["sender"])
        XCTAssertNil(events[0].payload["recipient"])
        XCTAssertNil(events[0].payload["content"])
        XCTAssertNil(events[0].payload["from"])
        XCTAssertNil(events[0].payload["to"])
    }
}
