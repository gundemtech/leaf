import Foundation

/// Phase Track-4 S2 — Reminders boundary value type. Carries only the list
/// name + the count delta of newly-completed items since the previous tick.
/// Individual reminder titles / bodies / notes never cross — only the
/// aggregate signal "user completed N items in the <list> list".
public struct RemindersCompletionObservation: AdapterObservation, Hashable {
    public let listName: String?
    public let completedCountDelta: Int

    public init(listName: String?, completedCountDelta: Int) {
        self.listName = listName
        self.completedCountDelta = completedCountDelta
    }
}
