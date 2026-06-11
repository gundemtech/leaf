import Testing

@testable import LeafCore

@Suite("AskLeafTranscript")
struct AskLeafTranscriptTests {
  @Test func askAppendsPendingEntry() {
    var t = AskLeafTranscript()
    let id = t.ask(question: "what did I do?", period: .last7Days, model: nil, askedAtMs: 1_000)
    #expect(id != nil)
    #expect(t.entries.count == 1)
    #expect(t.entries[0].question == "what did I do?")
    #expect(t.entries[0].phase == .pending)
    #expect(t.hasPending)
  }

  @Test func askTrimsAndRejectsEmptyQuestion() {
    var t = AskLeafTranscript()
    #expect(t.ask(question: "   \n", period: .today, model: nil, askedAtMs: 1) == nil)
    #expect(t.entries.isEmpty)
    let id = t.ask(question: "  hi  ", period: .today, model: nil, askedAtMs: 1)
    #expect(id != nil)
    #expect(t.entries[0].question == "hi")
  }

  @Test func askWhilePendingIsRejected() {
    var t = AskLeafTranscript()
    let first = t.ask(question: "a", period: .today, model: nil, askedAtMs: 1)
    #expect(first != nil)
    #expect(t.ask(question: "b", period: .today, model: nil, askedAtMs: 2) == nil)
    #expect(t.entries.count == 1)
  }

  @Test func resolveMapsAnswerToPhase() {
    var t = AskLeafTranscript()
    let id1 = t.ask(question: "a", period: .today, model: nil, askedAtMs: 1)!
    t.resolve(id: id1, with: .text("recap"))
    #expect(t.entries[0].phase == .answered("recap"))
    #expect(!t.hasPending)

    let id2 = t.ask(question: "b", period: .today, model: nil, askedAtMs: 2)!
    t.resolve(id: id2, with: .notEnoughData)
    #expect(t.entries[1].phase == .notEnoughData)

    let id3 = t.ask(question: "c", period: .today, model: nil, askedAtMs: 3)!
    let oops = AIFailure(kind: .transient, message: "oops")
    t.resolve(id: id3, with: .failure(oops))
    #expect(t.entries[2].phase == .failed(oops))
  }

  @Test func resolveUnknownOrSettledIdIsNoOp() {
    var t = AskLeafTranscript()
    t.resolve(id: 42, with: .text("x"))  // unknown — no crash, no change
    #expect(t.entries.isEmpty)
    let id = t.ask(question: "a", period: .today, model: nil, askedAtMs: 1)!
    t.resolve(id: id, with: .text("first"))
    t.resolve(id: id, with: .text("second"))  // already settled — keeps first
    #expect(t.entries[0].phase == .answered("first"))
  }

  @Test func idsAreUniqueAndIncreasing() {
    var t = AskLeafTranscript()
    let a = t.ask(question: "a", period: .today, model: nil, askedAtMs: 1)!
    t.resolve(id: a, with: .text("x"))
    let b = t.ask(question: "b", period: .today, model: nil, askedAtMs: 2)!
    #expect(b > a)
  }
}

// AI-UI-3 — terminal NL-intent suggestion entries.
extension AskLeafTranscriptTests {
  @Test func suggestHandoffAppendsTerminalEntry() {
    var t = AskLeafTranscript()
    let id = t.suggestHandoff(
      question: "передай Алисе про auth", recipientName: "Alice", topic: "auth",
      period: .last7Days, askedAtMs: 1)
    #expect(id != nil)
    #expect(t.entries.count == 1)
    #expect(t.hasPending == false)  // suggestion is terminal — input stays usable
    guard case .handoffSuggestion(let name, let topic) = t.entries[0].phase else {
      Issue.record("expected .handoffSuggestion")
      return
    }
    #expect(name == "Alice")
    #expect(topic == "auth")
  }

  @Test func suggestHandoffRespectsPendingSingleFlight() {
    var t = AskLeafTranscript()
    _ = t.ask(question: "q", period: .today, model: nil, askedAtMs: 1)
    let id = t.suggestHandoff(
      question: "tell Alice about x", recipientName: "Alice", topic: "x",
      period: .today, askedAtMs: 2)
    #expect(id == nil)
    #expect(t.entries.count == 1)
  }

  @Test func resolveIgnoresSuggestionEntries() {
    var t = AskLeafTranscript()
    let id = t.suggestHandoff(
      question: "tell Alice about x", recipientName: "Alice", topic: "x",
      period: .today, askedAtMs: 1)!
    t.resolve(id: id, with: .text("nope"))
    guard case .handoffSuggestion = t.entries[0].phase else {
      Issue.record("suggestion must stay terminal")
      return
    }
  }
}
