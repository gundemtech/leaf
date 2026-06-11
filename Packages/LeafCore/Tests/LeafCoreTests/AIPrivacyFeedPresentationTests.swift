// AI-UI-2 — AIPrivacyFeedPresentation: строки Privacy-лент «AI received» /
// «AI handoffs» из audit-таблиц M031/M032. Raw member-id в UI не отдаём.

import XCTest

@testable import LeafCore

final class AIPrivacyFeedPresentationTests: XCTestCase {
  private func escalationEntry(
    id: Int64 = 1, atMs: Int64 = 42_000, question: String? = "why", ids: [Int64] = [1, 2, 3]
  ) -> AIEscalationAuditStore.AuditEntryView {
    AIEscalationAuditStore.AuditEntryView(
      id: id, generatedAtMs: atMs, questionExcerpt: question, model: "haiku",
      eventIDs: ids, sourceSummary: "3 events")
  }

  private func handoffEntry(
    id: Int64 = 1, recipient: String? = "m-1", topic: String? = "auth refactor"
  ) -> HandoffAuditStore.AuditEntryView {
    HandoffAuditStore.AuditEntryView(
      id: id, generatedAtMs: 42_000, messageID: "msg-1", recipientMemberID: recipient,
      model: "haiku", path: "byok", periodStartMs: 0, periodEndMs: 1_000,
      factCount: 5, escalated: false, crosspostedSlack: true, crosspostedLinear: false,
      sourceSummary: "facts", topicExcerpt: topic)
  }

  private func member(id: String, name: String) -> TeamMember {
    TeamMember(
      id: id, workspaceID: "ws", role: .member, pubkeyHex: "00",
      displayName: name, addedAt: Date(timeIntervalSince1970: 0), removedAt: nil)
  }

  func testEscalationRows_mapped() {
    let rows = AIPrivacyFeedPresentation.escalationRows([escalationEntry()])
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].id, 1)
    XCTAssertEqual(rows[0].at, Date(timeIntervalSince1970: 42))
    XCTAssertEqual(rows[0].model, "haiku")
    XCTAssertEqual(rows[0].eventCount, 3)
    XCTAssertEqual(rows[0].question, "why")
    XCTAssertEqual(rows[0].sourceSummary, "3 events")
  }

  func testHandoffRows_recipientResolvedByID() {
    let rows = AIPrivacyFeedPresentation.handoffRows(
      [handoffEntry(recipient: "m-1")], members: [member(id: "m-1", name: "Alice")])
    XCTAssertEqual(rows[0].recipientName, "Alice")
    XCTAssertEqual(rows[0].factCount, 5)
    XCTAssertEqual(rows[0].topic, "auth refactor")
    XCTAssertTrue(rows[0].crosspostedSlack)
    XCTAssertFalse(rows[0].crosspostedLinear)
  }

  func testHandoffRows_unknownOrNilRecipient_fallsBack() {
    let members = [member(id: "m-1", name: "Alice")]
    let unknown = AIPrivacyFeedPresentation.handoffRows(
      [handoffEntry(recipient: "m-404")], members: members)
    XCTAssertEqual(unknown[0].recipientName, "Former teammate")
    let nilID = AIPrivacyFeedPresentation.handoffRows(
      [handoffEntry(recipient: nil)], members: members)
    XCTAssertEqual(nilID[0].recipientName, "Former teammate")
  }
}
