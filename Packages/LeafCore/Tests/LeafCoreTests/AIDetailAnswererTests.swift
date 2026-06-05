// Track AI Coworker P3 — escalation answerer (Suite C): audit-FIRST discipline.
// The audit row is written BEFORE the network POST, a failed audit aborts the
// send (no body crosses unrecorded), the row is structurally body-free, and
// droppedCount reflects bucket-1 drops. Fixtures use Alice/Eve/Alex placeholders.

import XCTest

@testable import LeafCore

private actor Recorder {
  var entries: [EscalationAuditEntry] = []
  var order: [String] = []
  var auditShouldThrow = false

  func setThrow() { auditShouldThrow = true }
  func recordAudit(_ e: EscalationAuditEntry) throws {
    if auditShouldThrow {
      throw SummarizerError.network("spy-audit-fail")  // any error
    }
    entries.append(e)
    order.append("audit")
  }
  func recordSummarize() { order.append("summarize") }
  func snapshotOrder() -> [String] { order }
  func snapshotEntries() -> [EscalationAuditEntry] { entries }
}

private struct SpyAuditSink: AuditSink {
  let rec: Recorder
  func record(_ entry: EscalationAuditEntry) async throws { try await rec.recordAudit(entry) }
}

private struct SpySummarizer: Summarizer {
  let rec: Recorder
  func summarize(_ context: PromptSafeContext, model: SummarizerModel, maxTokens: Int)
    async throws -> SummarizerOutput
  {
    await rec.recordSummarize()
    return SummarizerOutput(
      text: "base", usage: TokenUsage(inputTokens: 1, outputTokens: 1),
      modelUsed: model.apiModelID, stopReason: nil)
  }
  func summarize(
    _ context: PromptSafeContext, question: PromptSafeQuestion, escalated: EscalatedBodies,
    model: SummarizerModel, maxTokens: Int
  ) async throws -> SummarizerOutput {
    await rec.recordSummarize()
    return SummarizerOutput(
      text: "detail-answer", usage: TokenUsage(inputTokens: 1, outputTokens: 1),
      modelUsed: model.apiModelID, stopReason: nil)
  }
}

final class AIDetailAnswererTests: XCTestCase {
  private func event(_ kind: String, bundleID: String? = nil, _ payload: [String: String])
    -> EgressEvent
  {
    EgressEvent(
      timestamp: Date(timeIntervalSince1970: 5000), kind: kind, bundleID: bundleID, payload: payload)
  }

  private func answerer(rec: Recorder, policy: LLMPolicy = LLMPolicy()) -> AIDetailAnswerer {
    AIDetailAnswerer(
      policy: policy, summarizer: SpySummarizer(rec: rec), modelGate: DefaultModelGate(),
      audit: SpyAuditSink(rec: rec))
  }

  // 17. Audit row carries NO body text; positive gate eventIDs/count/question.
  func testAuditRowIsBodyFree() async {
    let rec = Recorder()
    _ = await answerer(rec: rec).answer(
      question: "summarize the discussion",
      eventIDs: [101, 202],
      selectedEvents: [event("gh_pr_review_comment_authored", ["body": "SENTINEL-AUDIT-BODY"])],
      nowMs: 9000)
    let entries = await rec.snapshotEntries()
    XCTAssertEqual(entries.count, 1)
    let e = entries[0]
    let flat = "\(e.eventIDs)|\(e.question)|\(e.model)|\(e.path)|\(e.sourceSummary)|\(e.escalatedBodyCount)|\(e.droppedCount)"
    XCTAssertFalse(flat.contains("SENTINEL-AUDIT-BODY"), "audit row must never carry body text")
    XCTAssertEqual(e.eventIDs, [101, 202])
    XCTAssertEqual(e.escalatedBodyCount, 1)
    XCTAssertTrue(e.question.contains("summarize the discussion"))
  }

  // 18. Audit is written BEFORE the POST.
  func testAuditWrittenBeforePost() async {
    let rec = Recorder()
    _ = await answerer(rec: rec).answer(
      question: "q", eventIDs: [1],
      selectedEvents: [event("gh_issue_comment_authored", ["body": "hi"])], nowMs: 1)
    let order = await rec.snapshotOrder()
    XCTAssertEqual(order, ["audit", "summarize"], "audit must precede the LLM POST")
  }

  // 19. Audit failure aborts the send (summarize NEVER called).
  func testAuditFailureAbortsSend() async {
    let rec = Recorder()
    await rec.setThrow()
    let answer = await answerer(rec: rec).answer(
      question: "q", eventIDs: [1],
      selectedEvents: [event("gh_pr_opened", ["body": "hi"])], nowMs: 1)
    let order = await rec.snapshotOrder()
    XCTAssertFalse(order.contains("summarize"), "a body must never cross unrecorded")
    if case .failure = answer { /* ok */ } else { XCTFail("expected .failure, got \(answer)") }
  }

  // 20. droppedCount reflects bucket-1 drops.
  func testDroppedCountReflectsBucket1() async {
    let rec = Recorder()
    let policy = LLMPolicy(moat: LLMEgressMoat(neverToCloudBundleIDs: ["com.test.personal"]))
    _ = await answerer(rec: rec, policy: policy).answer(
      question: "q", eventIDs: [1, 2, 3],
      selectedEvents: [
        event("gh_pr_review_comment_authored", ["body": "ok-1"]),
        event("attention", bundleID: "com.test.personal", ["body": "personal"]),
        event("gh_issue_comment_authored", ["body": "ok-2"]),
      ], nowMs: 1)
    let e = (await rec.snapshotEntries())[0]
    XCTAssertEqual(e.escalatedBodyCount, 2)
    XCTAssertEqual(e.droppedCount, 1)
  }

  // Nothing escalatable → notEnoughData, no audit, no POST.
  func testNothingToEscalate() async {
    let rec = Recorder()
    let answer = await answerer(rec: rec).answer(
      question: "q", eventIDs: [1],
      selectedEvents: [event("gh_pr_opened", [:])],  // no body, no projectable fact
      nowMs: 1)
    let order = await rec.snapshotOrder()
    XCTAssertTrue(order.isEmpty, "no audit + no POST when nothing escalatable")
    XCTAssertEqual(answer, .notEnoughData)
  }
}
