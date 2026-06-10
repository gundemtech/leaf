import Foundation

/// AI-UI-2 — чистая модель escalation-модалки (зеркало AskLeafTranscript):
/// кандидаты + выбор + фазы + single-flight. UI-клей (EscalationReader) только
/// дёргает переходы. Выбрать можно ТОЛЬКО sendable-кандидата (есть в preview);
/// кап выбора = consent-кап send-пути.
public struct EscalationDraft: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case composing
    case sending
    case answered(String)
    case failed(String)
  }

  public static let selectionCap = WorkFactGatherer.escalationEventIDCap

  /// Display-ready, newest-first.
  public let candidates: [ActivityFeedEntry]
  /// id → exactly-what-will-be-sent (EscalationPreviewBuilder). Отсутствие = dropped.
  public let preview: [Int64: EscalatedBody]
  public private(set) var selected: Set<Int64>
  public private(set) var phase: Phase = .composing

  public init(
    candidates: [ActivityFeedEntry], preview: [Int64: EscalatedBody], preselected: Set<Int64>
  ) {
    self.candidates = candidates
    self.preview = preview
    let sendable = preselected.intersection(preview.keys)
    self.selected = Set(sendable.sorted().prefix(Self.selectionCap))
  }

  public var sendableCount: Int { candidates.filter { preview[$0.id] != nil }.count }
  public var selectedCount: Int { selected.count }
  public func isSendable(_ id: Int64) -> Bool { preview[id] != nil }
  public func isSelected(_ id: Int64) -> Bool { selected.contains(id) }

  /// false — отказ: dropped-кандидат, превышение капа, либо phase != composing.
  @discardableResult
  public mutating func toggle(_ id: Int64) -> Bool {
    guard case .composing = phase, preview[id] != nil else { return false }
    if selected.contains(id) {
      selected.remove(id)
      return true
    }
    guard selected.count < Self.selectionCap else { return false }
    selected.insert(id)
    return true
  }

  /// Single-flight: только composing + непустой выбор.
  @discardableResult
  public mutating func beginSending() -> Bool {
    guard case .composing = phase, !selected.isEmpty else { return false }
    phase = .sending
    return true
  }

  public mutating func resolve(answer: String) {
    guard case .sending = phase else { return }
    phase = .answered(answer)
  }

  public mutating func fail(_ message: String) {
    guard case .sending = phase else { return }
    phase = .failed(message)
  }

  /// Retry после failed — обратно в composing (выбор сохранён).
  public mutating func reset() {
    guard case .failed = phase else { return }
    phase = .composing
  }
}
