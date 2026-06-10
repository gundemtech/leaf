// AI-UI-3 — the ONLY new projection through the §8.1 boundary: a teammate's
// inbound handoff note, wrapped as labeled HOSTILE data (authoredByViewer=false),
// capped like any escalated body.
import Foundation
import Testing

@testable import LeafCore

@Suite struct InboundHandoffPolicyTests {
  private let policy = LLMPolicy()

  @Test func wrapsTextAsForeignData() {
    let out = policy.makeInboundHandoff(
      text: "I refactored auth, pick up from PR #7", tsMs: 1_700_000_000_000)
    #expect(out.bodies.count == 1)
    #expect(out.bodies.first?.authoredByViewer == false)
    #expect(out.bodies.first?.kind == "inbound_handoff")
    #expect(out.bodies.first?.tsBucketMs == 1_700_000_000_000)
    #expect(out.bodies.first?.text == "I refactored auth, pick up from PR #7")
  }

  @Test func capsLongText() {
    let long = String(repeating: "a", count: LLMPolicy.escalationBodyCap + 500)
    let out = policy.makeInboundHandoff(text: long, tsMs: 0)
    // Parity with makeEscalation: BodyExcerpt.capped = cap chars + "…" marker.
    #expect((out.bodies.first?.text.count ?? .max) <= LLMPolicy.escalationBodyCap + 1)
    #expect(out.bodies.first?.text.hasSuffix("…") == true)
  }

  @Test func emptyAndWhitespaceTextYieldNothing() {
    #expect(policy.makeInboundHandoff(text: "", tsMs: 0).bodies.isEmpty)
    #expect(policy.makeInboundHandoff(text: "  \n\t ", tsMs: 0).bodies.isEmpty)
  }
}
