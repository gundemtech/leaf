import Foundation

/// Track-6 P4 — Google Calendar Deep. 6 event_kind discriminators emitted
/// by `GoogleCalendarCollector`: 1 omnibus snapshot (`_event_observed`) +
/// 5 clock-driven transitions (focus_block / ooo paired; workingLocation
/// single-shot). Rationale: spec §6, brainstorm BR-1.
public enum GoogleCalendarEventKind: String, CaseIterable, Sendable {
    case eventObserved              = "google_calendar_event_observed"
    case focusBlockStarted          = "google_calendar_focus_block_started"
    case focusBlockEnded            = "google_calendar_focus_block_ended"
    case oooStarted                 = "google_calendar_ooo_started"
    case oooEnded                   = "google_calendar_ooo_ended"
    case workingLocationChanged     = "google_calendar_working_location_changed"
}
