import Foundation

/// Orthogonal classification of events; see whitepaper section 6.
/// Content type L6 does not exist as a case — won't-list enforced at the compiler level.
public enum SignalType: String, Codable, Sendable, CaseIterable {
    case attention
    case content
    case action
    case context
    case aiCollaboration
}
