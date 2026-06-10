import Foundation

/// AI-UI-1 — in-memory транскрипт вкладки «Ask Leaf». Чистая модель (без I/O),
/// живёт в LeafCore ради SPM-тестов (app-таргет без тест-бандла). Каждый вопрос
/// независим (паритет с MCP ask_about_my_work — без multi-turn контекста);
/// однополётность enforced на уровне модели: новый ask при pending → nil.
public struct AskLeafTranscript: Equatable, Sendable {
  public struct Entry: Identifiable, Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
      case pending
      case answered(String)
      case notEnoughData
      case failed(String)
      /// AI-UI-3 — terminal NL-intent suggestion: no LLM ran; the UI renders
      /// [Create handoff for <name>] / [Ask anyway] actions instead of an answer.
      case handoffSuggestion(recipientName: String, topic: String)
    }

    public let id: Int
    public let question: String
    public let period: ReviewActivityInsights.ReviewActivityPeriod
    public let model: SummarizerModel?
    public let askedAtMs: Int64
    public var phase: Phase
  }

  public private(set) var entries: [Entry] = []
  private var nextID = 1

  public init() {}

  public var hasPending: Bool { entries.contains { $0.phase == .pending } }

  /// Append a pending entry. Returns nil (and appends nothing) for an
  /// empty-after-trim question or while a previous ask is still pending.
  public mutating func ask(
    question raw: String,
    period: ReviewActivityInsights.ReviewActivityPeriod,
    model: SummarizerModel?,
    askedAtMs: Int64
  ) -> Int? {
    let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, !hasPending else { return nil }
    let id = nextID
    nextID += 1
    entries.append(
      Entry(
        id: id, question: question, period: period, model: model,
        askedAtMs: askedAtMs, phase: .pending))
    return id
  }

  /// AI-UI-3 — append a TERMINAL handoff suggestion (the question matched the
  /// local intent parser; no LLM call happened). Mirrors ask()'s guards so a
  /// pending answer still blocks new input.
  public mutating func suggestHandoff(
    question raw: String,
    recipientName: String,
    topic: String,
    period: ReviewActivityInsights.ReviewActivityPeriod,
    askedAtMs: Int64
  ) -> Int? {
    let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, !hasPending else { return nil }
    let id = nextID
    nextID += 1
    entries.append(
      Entry(
        id: id, question: question, period: period, model: nil,
        askedAtMs: askedAtMs,
        phase: .handoffSuggestion(recipientName: recipientName, topic: topic)))
    return id
  }

  /// Settle a pending entry. Unknown id / already-settled entry — no-op.
  public mutating func resolve(id: Int, with answer: AIWorkAnswerer.Answer) {
    guard let idx = entries.firstIndex(where: { $0.id == id }),
      entries[idx].phase == .pending
    else { return }
    switch answer {
    case .text(let text): entries[idx].phase = .answered(text)
    case .notEnoughData: entries[idx].phase = .notEnoughData
    case .failure(let msg): entries[idx].phase = .failed(msg)
    }
  }
}
