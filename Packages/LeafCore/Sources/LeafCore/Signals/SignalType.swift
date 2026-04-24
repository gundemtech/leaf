import Foundation

/// Ортогональная классификация событий; см. whitepaper раздел 6.
/// Content type L6 не существует как case — won't-list на уровне компилятора.
public enum SignalType: String, Codable, Sendable, CaseIterable {
    case attention
    case content
    case action
    case context
    case aiCollaboration
}
