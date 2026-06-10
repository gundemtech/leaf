import Foundation

/// AI-UI-3 — local NL detection of "hand this off to <teammate>" in the Ask
/// Leaf input. Pure heuristics, zero egress, deterministic. A hit only ever
/// produces a SUGGESTION chip (the user confirms before any draft happens),
/// so precision beats recall: ambiguity or no roster match → nil → normal Q&A.
public enum HandoffIntentParser {
  public struct Hit: Equatable, Sendable {
    public let recipientName: String  // the ROSTER display name (not the typed form)
    public let topic: String
    public init(recipientName: String, topic: String) {
      self.recipientName = recipientName
      self.topic = topic
    }
  }

  /// Each pattern captures (1) the name token and (2) the topic remainder.
  /// The name→topic separator is REQUIRED (punctuation or whitespace) — without
  /// it, regex backtracking splits a bare name ("Алисе" → "Алис" + topic "е").
  private static let sep = #"(?:\s*[:,—–-]\s*|\s+)"#
  private static let patterns: [String] = [
    // EN
    #"^(?:please\s+)?hand\s*-?\s*off\s+(?:this\s+)?(?:to|for)\s+(\p{L}+)"# + sep
      + #"(?:about\s+)?(.+)$"#,
    #"^tell\s+(\p{L}+)\s+about\s+(.+)$"#,
    // RU
    #"^передай(?:те)?\s+(\p{L}+)"# + sep + #"(?:про\s+|о\s+|об\s+)?(.+)$"#,
    #"^расскажи(?:те)?\s+(\p{L}+)\s+(?:про|о|об)\s+(.+)$"#,
    #"^х[еэ]ндофф?\s+(?:для|на)\s+(\p{L}+)"# + sep + #"(.+)$"#,
  ]

  public static func parse(question: String, rosterNames: [String]) -> Hit? {
    guard !rosterNames.isEmpty else { return nil }
    let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
    for pattern in patterns {
      guard
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
        let m = regex.firstMatch(in: q, options: [], range: NSRange(q.startIndex..., in: q)),
        m.numberOfRanges == 3,
        let nameRange = Range(m.range(at: 1), in: q),
        let topicRange = Range(m.range(at: 2), in: q)
      else { continue }
      let nameToken = String(q[nameRange])
      let topic = String(q[topicRange])
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "?!."))
      guard !topic.isEmpty, let resolved = matchRoster(nameToken, rosterNames: rosterNames)
      else { continue }
      return Hit(recipientName: resolved, topic: topic)
    }
    return nil
  }

  /// Unique FIRST-NAME match, case/diacritic-insensitive. A roster name matches
  /// when the typed token is exact, a ≥3-char prefix relation either way
  /// (Alex↔Alexandra), or a declension stem — common prefix covering all but
  /// ≤2 trailing chars of the longer form (Алисе↔Алиса, Евы↔Ева; Anna↔Anton
  /// misses). More than one DISTINCT roster hit → nil (ambiguous).
  static func matchRoster(_ token: String, rosterNames: [String]) -> String? {
    func fold(_ s: String) -> String {
      s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }
    let t = fold(token)
    guard t.count >= 2 else { return nil }
    var hits: [String] = []
    for name in rosterNames {
      guard let first = name.split(separator: " ").first.map({ fold(String($0)) }), !first.isEmpty
      else { continue }
      let common = t.commonPrefix(with: first).count
      let stemThreshold = Swift.max(2, Swift.max(t.count, first.count) - 2)
      let ok =
        t == first
        || (t.count >= 3 && first.hasPrefix(t))
        || (first.count >= 3 && t.hasPrefix(first))
        || common >= stemThreshold
      if ok { hits.append(name) }
    }
    return Set(hits).count == 1 ? hits.first : nil
  }
}
