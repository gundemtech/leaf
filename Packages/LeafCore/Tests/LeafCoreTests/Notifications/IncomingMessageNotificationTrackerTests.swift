import XCTest

@testable import LeafCore

/// Dedup + first-poll-batch suppression for incoming-DM local notifications.
/// Pure value-semantics state machine the reader owns (the reader is @MainActor
/// app-target glue with no unit-test bundle; the logic lives here, tested).
///
/// Model (see plan §Dedup): Realtime = always live (notify unless already seen);
/// Polling = suppress the FIRST batch per workspace per session (backlog / arrived
/// while app was closed), notify subsequent. Both share one notified-id set.
final class IncomingMessageNotificationTrackerTests: XCTestCase {

  func test_realtime_firstSightNotifies_repeatSuppressed() {
    var t = IncomingMessageNotificationTracker()
    XCTAssertTrue(t.shouldNotifyRealtime(messageID: "m1"))
    XCTAssertFalse(t.shouldNotifyRealtime(messageID: "m1"))
  }

  func test_polling_firstBatchSuppressed() {
    var t = IncomingMessageNotificationTracker()
    let out = t.notifiablePolledMessageIDs(workspaceID: "ws1", messageIDs: ["a", "b"])
    XCTAssertEqual(out, [])
  }

  func test_polling_secondBatchNotifiesNewIDs() {
    var t = IncomingMessageNotificationTracker()
    _ = t.notifiablePolledMessageIDs(workspaceID: "ws1", messageIDs: ["a"])  // backlog
    let out = t.notifiablePolledMessageIDs(workspaceID: "ws1", messageIDs: ["b", "c"])
    XCTAssertEqual(out, ["b", "c"])
  }

  func test_polling_firstBatchRecordsIDs_soLaterRealtimeDoesNotReNotify() {
    var t = IncomingMessageNotificationTracker()
    _ = t.notifiablePolledMessageIDs(workspaceID: "ws1", messageIDs: ["a"])  // backlog records "a"
    XCTAssertFalse(t.shouldNotifyRealtime(messageID: "a"))
  }

  func test_polling_secondBatchDedupesAgainstRealtime() {
    var t = IncomingMessageNotificationTracker()
    _ = t.notifiablePolledMessageIDs(workspaceID: "ws1", messageIDs: [])  // arm ws1
    XCTAssertTrue(t.shouldNotifyRealtime(messageID: "x"))                  // realtime notified x
    let out = t.notifiablePolledMessageIDs(workspaceID: "ws1", messageIDs: ["x", "y"])
    XCTAssertEqual(out, ["y"], "x already notified via realtime → only y")
  }

  func test_workspacesTrackedIndependently_eachFirstBatchSuppressed() {
    var t = IncomingMessageNotificationTracker()
    XCTAssertEqual(t.notifiablePolledMessageIDs(workspaceID: "ws1", messageIDs: ["a"]), [])
    XCTAssertEqual(t.notifiablePolledMessageIDs(workspaceID: "ws2", messageIDs: ["b"]), [],
                   "ws2 first batch is its own backlog")
    XCTAssertEqual(t.notifiablePolledMessageIDs(workspaceID: "ws1", messageIDs: ["c"]), ["c"])
  }
}
