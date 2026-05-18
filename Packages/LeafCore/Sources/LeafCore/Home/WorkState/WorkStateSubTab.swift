import Foundation

/// Second-level tab strip inside `WorkStateDetailScreen` — selects which D3
/// surface the aggregates+list blocks render.
public enum WorkStateSubTab: String, Hashable, Identifiable, CaseIterable, Sendable {
    case decisions
    case questions
    case blockers
    case whereStopped = "where_stopped"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .decisions: return "Decisions"
        case .questions: return "Questions"
        case .blockers: return "Blockers"
        case .whereStopped: return "Where Stopped"
        }
    }
}
