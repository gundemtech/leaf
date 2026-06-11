import XCTest

@testable import LeafCore

/// Local-notification gating + content for incoming DMs. Pure decision matrix —
/// the app's `LocalMessageNotifier` maps a returned `MessageNotificationPlan` to
/// a `UNNotificationRequest`. Dedup is NOT the decider's job (the reader owns the
/// `notifiedMessageIDs` / `polledWorkspaces` sets); this fn holds gating + copy.
///
/// User decisions pinned here: scope = DM only; content = `.bodyPreview`; master
/// off-switch silences everything EXCEPT handoff (`masterCanSilenceHandoff=false`).
final class IncomingMessageNotificationDeciderTests: XCTestCase {

  private func decide(
    messageID: String = "m1",
    workspaceID: String = "ws1",
    kind: DirectMessageKind = .task,
    direction: DirectMessageMirrorRow.Direction = .inbound,
    senderDisplayName: String = "Sasha",
    body: String = "ship it",
    readAtMs: Int64? = nil,
    masterEnabled: Bool = true,
    kindEnabled: Bool = true,
    soundEnabled: Bool = true,
    bodyStyle: NotificationBodyStyle = .bodyPreview,
    masterCanSilenceHandoff: Bool = false
  ) -> MessageNotificationPlan? {
    IncomingMessageNotificationDecider.decide(
      messageID: messageID, workspaceID: workspaceID, kind: kind, direction: direction,
      senderDisplayName: senderDisplayName, body: body, readAtMs: readAtMs,
      masterEnabled: masterEnabled, kindEnabled: kindEnabled, soundEnabled: soundEnabled,
      bodyStyle: bodyStyle, masterCanSilenceHandoff: masterCanSilenceHandoff)
  }

  // MARK: - Hard gates

  func test_outbound_returnsNil() {
    XCTAssertNil(decide(direction: .outbound))
  }

  func test_alreadyRead_returnsNil() {
    XCTAssertNil(decide(readAtMs: 1_700_000_000_000))
  }

  // MARK: - Master + per-kind

  func test_task_notifiesByDefault() {
    XCTAssertNotNil(decide(kind: .task))
  }

  func test_masterOff_silencesTask() {
    XCTAssertNil(decide(kind: .task, masterEnabled: false))
  }

  func test_masterOff_silencesPing() {
    XCTAssertNil(decide(kind: .ping, masterEnabled: false))
  }

  func test_masterOff_handoffStillNotifies_whenCannotSilenceHandoff() {
    XCTAssertNotNil(decide(kind: .handoff, masterEnabled: false, masterCanSilenceHandoff: false))
  }

  func test_masterOff_handoffSilenced_whenMasterCanSilenceHandoff() {
    XCTAssertNil(decide(kind: .handoff, masterEnabled: false, masterCanSilenceHandoff: true))
  }

  func test_perKindOff_silencesTask() {
    XCTAssertNil(decide(kind: .task, kindEnabled: false))
  }

  func test_handoffIgnoresPerKindOff_lockedOn() {
    // handoff is locked-ON: a stray kindEnabled=false must NOT silence it.
    XCTAssertNotNil(decide(kind: .handoff, kindEnabled: false))
  }

  // MARK: - Identifier + category

  func test_identifier_isStablePerMessage() {
    XCTAssertEqual(decide(messageID: "abc")?.identifier, "leaf.dm.abc")
  }

  func test_categoryID_matchesKind() {
    XCTAssertEqual(decide(kind: .handoff)?.categoryID, "leaf.dm.handoff")
    XCTAssertEqual(decide(kind: .task)?.categoryID, "leaf.dm.task")
    XCTAssertEqual(decide(kind: .ping)?.categoryID, "leaf.dm.ping")
  }

  func test_plan_carriesWorkspaceAndMessageIDsAndSound() {
    let p = decide(messageID: "m9", workspaceID: "wsX", soundEnabled: false)
    XCTAssertEqual(p?.messageID, "m9")
    XCTAssertEqual(p?.workspaceID, "wsX")
    XCTAssertEqual(p?.soundEnabled, false)
  }

  // MARK: - Content (.bodyPreview)

  func test_bodyPreview_titleIsSender_bodyIsText() {
    let p = decide(kind: .task, senderDisplayName: "Sasha", body: "review PR 42", bodyStyle: .bodyPreview)
    XCTAssertEqual(p?.title, "Sasha")
    XCTAssertEqual(p?.body, "review PR 42")
  }

  func test_bodyPreview_truncatesLongBodyTo140() {
    let long = String(repeating: "x", count: 300)
    let p = decide(body: long, bodyStyle: .bodyPreview)
    XCTAssertLessThanOrEqual(p?.body.count ?? 999, 140)
    XCTAssertTrue(p?.body.hasSuffix("\u{2026}") ?? false)
  }

  func test_bodyPreview_emptyBodyFallsBackToKindVerb() {
    XCTAssertEqual(decide(kind: .ping, body: "", bodyStyle: .bodyPreview)?.body, "pinged you")
    XCTAssertEqual(decide(kind: .handoff, body: "   ", bodyStyle: .bodyPreview)?.body, "sent you a handoff")
    XCTAssertEqual(decide(kind: .task, body: "", bodyStyle: .bodyPreview)?.body, "assigned you a task")
  }

  func test_emptySenderName_titleFallsBackToKind() {
    XCTAssertEqual(decide(kind: .handoff, senderDisplayName: "", bodyStyle: .bodyPreview)?.title, "New handoff")
  }

  // MARK: - Content (.generic alternate)

  func test_generic_bodyIsVerbNotMessageText() {
    let p = decide(kind: .task, senderDisplayName: "Sasha", body: "secret content", bodyStyle: .generic)
    XCTAssertEqual(p?.title, "Sasha")
    XCTAssertEqual(p?.body, "assigned you a task")
  }
}
