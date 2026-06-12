// Use-case rebuild Track C (UC-4) — handoff context card protocol tests.
//
// Golden-fixture tolerance suite (the load-bearing part): old-shape
// plaintexts, +snapshot plaintexts, corrupt snapshots and future (v2)
// snapshots must all decode without ever failing the whole
// DirectMessagePlaintext — the cross_post jsonb incident (one bad row killed
// whole inbound batches) is the anti-pattern this locks out.

import XCTest
@testable import LeafCore

final class HandoffContextSnapshotTests: XCTestCase {

  // MARK: - Fixtures

  private func basePlaintextJSON(extra: String = "") -> String {
    """
    {
      "message_id": "m1",
      "workspace_id": "ws1",
      "sender_member_id": "member-a",
      "sender_pubkey_hex": "aa",
      "sender_display_name": "Alex",
      "recipient_member_id": "member-b",
      "recipient_pubkey_hex": "bb",
      "kind": "handoff",
      "body": "Picking up the auth refactor tomorrow.",
      "reply_to": null,
      "sent_at_ms": 1000\(extra)
    }
    """
  }

  private let snapshotJSON = """
    ,
      "context_snapshot": {
        "schema_version": 1,
        "title": "auth refactor",
        "last_commit": {"sha": "a3f2c1d", "subject": "feat: token rotation",
                        "branch": "auth-refactor", "repo": "acme/widget", "ts_ms": 900},
        "open_review": {"ref": "acme/widget#142", "comment_count": 3,
                        "url": "https://github.com/acme/widget/pull/142"},
        "ticket": {"ref": "LEA-431", "state": "In Progress", "cycle": "sprint 14"},
        "last_thread": {"channel": "engineering", "message_count": 8},
        "captured_at_ms": 1000
      }
    """

  private func decodePlaintext(_ json: String) throws -> DirectMessagePlaintext {
    try JSONDecoder().decode(DirectMessagePlaintext.self, from: Data(json.utf8))
  }

  // MARK: - Wire tolerance

  func testOldShapePlaintext_DecodesWithNilSnapshot() throws {
    let plaintext = try decodePlaintext(basePlaintextJSON())
    XCTAssertNil(plaintext.contextSnapshot)
    XCTAssertEqual(plaintext.body, "Picking up the auth refactor tomorrow.")
  }

  func testSnapshotPlaintext_RoundTripsAllLines() throws {
    let plaintext = try decodePlaintext(basePlaintextJSON(extra: snapshotJSON))
    let snapshot = try XCTUnwrap(plaintext.contextSnapshot)
    XCTAssertEqual(snapshot.title, "auth refactor")
    XCTAssertEqual(snapshot.lastCommit?.subject, "feat: token rotation")
    XCTAssertEqual(snapshot.openReview?.ref, "acme/widget#142")
    XCTAssertEqual(snapshot.openReview?.commentCount, 3)
    XCTAssertEqual(snapshot.ticket?.state, "In Progress")
    XCTAssertEqual(snapshot.ticket?.cycle, "sprint 14")
    XCTAssertEqual(snapshot.lastThread?.channel, "engineering")
    XCTAssertEqual(snapshot.lastThread?.messageCount, 8)
    XCTAssertTrue(snapshot.hasAnyLine)

    // Encoder round-trip: snake_case wire keys stable.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let reencoded = String(data: try encoder.encode(plaintext), encoding: .utf8)!
    XCTAssertTrue(reencoded.contains("\"context_snapshot\""))
    XCTAssertTrue(reencoded.contains("\"last_commit\""))
    XCTAssertTrue(reencoded.contains("\"captured_at_ms\""))
  }

  func testCorruptSnapshot_DegradesToNil_PlaintextSurvives() throws {
    let corrupt = #", "context_snapshot": "not-an-object""#
    let plaintext = try decodePlaintext(basePlaintextJSON(extra: corrupt))
    XCTAssertNil(plaintext.contextSnapshot, "snapshot rot must degrade to nil")
    XCTAssertEqual(plaintext.messageID, "m1", "plaintext itself must survive")
  }

  func testFutureV2Snapshot_RendersKnownLines() throws {
    let v2 = """
      ,
      "context_snapshot": {
        "schema_version": 2,
        "title": "auth refactor",
        "last_commit": {"sha": "a3f2", "subject": "feat: x", "unknown_field": [1,2]},
        "brand_new_line": {"whatever": true},
        "captured_at_ms": 1000
      }
      """
    let plaintext = try decodePlaintext(basePlaintextJSON(extra: v2))
    let snapshot = try XCTUnwrap(plaintext.contextSnapshot)
    XCTAssertEqual(snapshot.schemaVersion, 2)
    XCTAssertEqual(snapshot.lastCommit?.subject, "feat: x")
    XCTAssertNil(snapshot.openReview)
  }

  func testMalformedRequiredField_StillThrows() {
    // Tolerance is for the SNAPSHOT only — a truly broken plaintext (missing
    // body) must keep throwing so the per-row skip in the inbox catches it.
    let broken = basePlaintextJSON().replacingOccurrences(
      of: "\"body\": \"Picking up the auth refactor tomorrow.\",", with: "")
    XCTAssertThrowsError(try decodePlaintext(broken))
  }

  // MARK: - Builder (sender side)

  func testBuilder_ProjectsCurrentWorkIntoLines() {
    let work = CurrentWorkResponse(
      currentApp: "com.apple.dt.Xcode",
      currentBranch: "auth-refactor",
      currentFile: nil,
      inProgressLinearTicket: LinearTicketRef(issueRef: "LEA-431", title: "T", stateName: "In Progress"),
      lastCommit: CommitRef(
        sha: "a3f2c1d9", message: "feat: token rotation\n\nbody", branch: "auth-refactor",
        pushedAtMs: 900, subject: "feat: token rotation", repoFullName: "acme/widget"),
      openPR: OpenPRRef(ref: "acme/widget#142", title: "Auth", commentCount: 3,
                        url: "https://github.com/acme/widget/pull/142", openedAtMs: 800),
      lastThread: ThreadRef(channelName: "engineering", messageCount: 8, tsMs: 700),
      currentOpenQuestions: [], currentBlockers: [], whereStopped: nil)

    let snapshot = HandoffSnapshotBuilder.build(from: work, title: "auth refactor", nowMs: 1_000)
    XCTAssertEqual(snapshot.lastCommit?.subject, "feat: token rotation")
    XCTAssertEqual(snapshot.lastCommit?.repo, "acme/widget")
    XCTAssertEqual(snapshot.openReview?.ref, "acme/widget#142")
    XCTAssertEqual(snapshot.ticket?.ref, "LEA-431")
    XCTAssertEqual(snapshot.lastThread?.channel, "engineering")
    XCTAssertEqual(snapshot.capturedAtMs, 1_000)
  }

  func testBuilder_EmptyWork_NoLines() {
    let work = CurrentWorkResponse(
      currentApp: nil, currentBranch: nil, currentFile: nil,
      inProgressLinearTicket: nil, lastCommit: nil,
      currentOpenQuestions: [], currentBlockers: [], whereStopped: nil)
    let snapshot = HandoffSnapshotBuilder.build(from: work, title: nil, nowMs: 1)
    XCTAssertFalse(snapshot.hasAnyLine)
  }

  // MARK: - Presentation (recipient side)

  func testPresentation_FourRowsWithMockupCopy() throws {
    let plaintext = try decodePlaintext(basePlaintextJSON(extra: snapshotJSON))
    let snapshot = try XCTUnwrap(plaintext.contextSnapshot)
    // now = 2h after the commit ts.
    let rows = HandoffCardPresentation.rows(from: snapshot, nowMs: 900 + 2 * 3_600_000)

    XCTAssertEqual(rows.map(\.label), ["LAST COMMIT", "OPEN REVIEW", "STATUS", "LAST THREAD"])
    XCTAssertEqual(rows[0].value, "feat: token rotation · 2h ago")
    XCTAssertEqual(rows[0].accentPrefix, "feat:")
    XCTAssertEqual(rows[1].value, "#142 · 3 comments")
    XCTAssertEqual(rows[2].value, "In Progress · sprint 14")
    XCTAssertEqual(rows[3].value, "#engineering · 8 msgs")
    XCTAssertEqual(
      HandoffCardPresentation.headerTitle(from: snapshot), "handoff · auth refactor")
  }

  // MARK: - Mirror store round-trip

  func testMirrorStore_PersistsAndReadsSnapshot() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-c-mirror-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let db = try LeafCore.Database.openForWrite(
      at: tempDir.appendingPathComponent("events.sqlite"),
      config: .weakDefaults, encryption: .deterministicTest)

    let snapshot = HandoffContextSnapshot(
      title: "auth refactor",
      lastCommit: .init(sha: "a3f2", subject: "feat: x", branch: "b", repo: "a/w", tsMs: 1),
      openReview: nil, ticket: nil, lastThread: nil, capturedAtMs: 2)
    let row = DirectMessageMirrorRow(
      messageID: "m1", workspaceID: "ws", senderPubkeyHex: "aa",
      senderMemberID: "ma", senderDisplayName: "Alex", recipientPubkeyHex: "bb",
      kind: .handoff, body: "text", contextSnapshot: snapshot,
      sentAtMs: 1, serverCreatedAtMs: 1, direction: .inbound, lastSyncedAtMs: 1)

    try db.writeSQL { rawDB in
      try MessagesMirrorStore.upsert(row, in: rawDB)
    }
    let readBack = try db.readSQL { rawDB in
      try MessagesMirrorStore.read(messageID: "m1", in: rawDB)
    }
    XCTAssertEqual(readBack?.contextSnapshot, snapshot)
  }
}
