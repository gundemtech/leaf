// AI-UI-3 — local NL handoff-intent detection (zero egress, deterministic).
// EN + RU patterns; the name must UNIQUELY match the roster or the parser
// declines (nil → the question goes to normal Q&A; a false miss is harmless).
import Testing

@testable import LeafCore

@Suite struct HandoffIntentParserTests {
  private let roster = ["Alice Johnson", "Eve Stone", "Alex Lee"]

  // EN hits
  @Test func englishHandOffTo() {
    let hit = HandoffIntentParser.parse(
      question: "hand off to Alice: the auth refactor", rosterNames: roster)
    #expect(hit == .init(recipientName: "Alice Johnson", topic: "the auth refactor"))
  }
  @Test func englishHandoffFor() {
    let hit = HandoffIntentParser.parse(
      question: "handoff for Eve about billing flow", rosterNames: roster)
    #expect(hit?.recipientName == "Eve Stone")
    #expect(hit?.topic == "billing flow")
  }
  @Test func englishTellAbout() {
    let hit = HandoffIntentParser.parse(
      question: "tell Alex about the relay migration", rosterNames: roster)
    #expect(hit?.recipientName == "Alex Lee")
    #expect(hit?.topic == "the relay migration")
  }

  // RU hits (incl. declension: Алисе → Алиса via stem match)
  @Test func russianPeredai() {
    let hit = HandoffIntentParser.parse(
      question: "передай Алисе про рефактор auth", rosterNames: ["Алиса", "Ева"])
    #expect(hit?.recipientName == "Алиса")
    #expect(hit?.topic == "рефактор auth")
  }
  @Test func russianRasskazhi() {
    let hit = HandoffIntentParser.parse(
      question: "расскажи Еве о статусе релиза", rosterNames: ["Алиса", "Ева"])
    #expect(hit?.recipientName == "Ева")
    #expect(hit?.topic == "статусе релиза")
  }
  @Test func russianHandoffDlya() {
    let hit = HandoffIntentParser.parse(
      question: "хендофф для Евы: миграция", rosterNames: ["Алиса", "Ева"])
    #expect(hit?.recipientName == "Ева")
    #expect(hit?.topic == "миграция")
  }

  // Declines
  @Test func ambiguousNameDeclines() {
    let hit = HandoffIntentParser.parse(
      question: "hand off to Alex: stuff", rosterNames: ["Alex Lee", "Alexandra Park"])
    #expect(hit == nil)
  }
  @Test func unknownNameDeclines() {
    #expect(HandoffIntentParser.parse(question: "tell Bob about x", rosterNames: roster) == nil)
  }
  @Test func emptyRosterDeclines() {
    #expect(HandoffIntentParser.parse(question: "hand off to Alice: x", rosterNames: []) == nil)
  }
  @Test func emptyTopicDeclines() {
    #expect(HandoffIntentParser.parse(question: "hand off to Alice", rosterNames: roster) == nil)
    #expect(HandoffIntentParser.parse(question: "передай Алисе", rosterNames: ["Алиса"]) == nil)
  }
  @Test func ordinaryQuestionsDecline() {
    for q in [
      "What did I work on this week?",
      "Where did I stop yesterday?",
      "Which PRs map to which Linear issues?",
      "tell me about my week",  // "me" is not a roster name
      "когда я закончил рефактор?",
    ] {
      #expect(HandoffIntentParser.parse(question: q, rosterNames: roster) == nil, "false hit: \(q)")
    }
  }
}
