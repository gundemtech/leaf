import Foundation

/// Phase Track-4 S1 — OS-boundary value type carrying ONLY whether the user is
/// currently in a meeting. Translated from `EKEvent` instances at the
/// CalendarCollector boundary in LeafAgent — by design holds no title,
/// location, attendee, organiser, or notes data. Compile-time guarantee that
/// the rest of the codebase cannot accidentally surface meeting PII.
public struct MeetingObservation: Sendable, Hashable {
    public let isInMeeting: Bool

    public init(isInMeeting: Bool) {
        self.isInMeeting = isInMeeting
    }
}
