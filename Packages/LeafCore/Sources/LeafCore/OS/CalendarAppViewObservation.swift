import Foundation

public enum CalendarAppViewMode: String, Sendable, Codable, Hashable {
    case day
    case week
    case month
    case year
    case unknown
}

/// Phase Track-4 S2 — Calendar.app UI-view boundary type. Captures only how
/// the user is *viewing* their calendar (Day / Week / Month + visible date
/// span). Event titles, summaries, descriptions, locations, attendees never
/// cross — those are owned by S1 `CalendarCollector` which is permission-
/// gated through EventKit and only emits the boolean `in_meeting` signal.
public struct CalendarAppViewObservation: AdapterObservation, Hashable {
    public let viewMode: CalendarAppViewMode
    public let visibleDateRangeDays: Int

    public init(viewMode: CalendarAppViewMode, visibleDateRangeDays: Int) {
        self.viewMode = viewMode
        self.visibleDateRangeDays = visibleDateRangeDays
    }
}
