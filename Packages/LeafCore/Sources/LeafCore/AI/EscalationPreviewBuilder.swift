import Foundation

/// AI-UI-2 — consent-preview эскалации: per-event проекция через ТУ ЖЕ
/// LLMPolicy.makeEscalation (она per-event независима — compactMap), т.е.
/// preview-текст = ровно то, что уйдёт при confirm. Локально, без egress.
/// Отсутствие id в результате = событие dropped (bucket-1 / нет body).
public enum EscalationPreviewBuilder {
  public static func preview(
    keyed: [(id: Int64, event: EgressEvent)],
    policy: LLMPolicy
  ) -> [Int64: EscalatedBody] {
    var out: [Int64: EscalatedBody] = [:]
    for (id, e) in keyed {
      if let body = policy.makeEscalation(selected: [e]).bodies.first {
        out[id] = body
      }
    }
    return out
  }
}
