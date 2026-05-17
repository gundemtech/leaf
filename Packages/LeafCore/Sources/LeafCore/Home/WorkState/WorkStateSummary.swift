import Foundation

/// Card-level summary of D3 Work State surface — drives both the Home card
/// (`WorkStateCard` headline + sub-line) and is reused as the snapshot field
/// `InsightsSnapshot.workState`.
public struct WorkStateSummary: Equatable, Hashable, Sendable {
    public let openQuestionsCount: Int
    public let openBlockersCount: Int
    public let lastDecisionExcerpt: String?
    public let lastDecisionAgeMs: Int64?

    public init(
        openQuestionsCount: Int,
        openBlockersCount: Int,
        lastDecisionExcerpt: String?,
        lastDecisionAgeMs: Int64?
    ) {
        self.openQuestionsCount = openQuestionsCount
        self.openBlockersCount = openBlockersCount
        self.lastDecisionExcerpt = lastDecisionExcerpt
        self.lastDecisionAgeMs = lastDecisionAgeMs
    }

    public static let empty = WorkStateSummary(
        openQuestionsCount: 0,
        openBlockersCount: 0,
        lastDecisionExcerpt: nil,
        lastDecisionAgeMs: nil
    )
}
