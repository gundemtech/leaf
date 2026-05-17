import Foundation

/// Track-6 P4 Task 6 — Omnibus `_event_observed` payload builder.
///
/// **Where ADR-010 lives.** `GoogleCalendarAPI.Event` decodes a superset of
/// fields (description / location / attendee.email / htmlLink / declineMessage,
/// etc.) because some are needed INTERNALLY by the mapper (e.g. attendee.email
/// for external-domain counting) — but the output dictionary returned here
/// MUST NOT include any of them. Privacy walkbacks live in the tests; this
/// file's job is to never add a key for those fields in the first place.
///
/// Spec §6.3 (omnibus shape) + §6.4 (forbidden output keys).
public struct GoogleCalendarEventMapper: Sendable {

    /// Convert a decoded `Event` into the omnibus `google_calendar_event_observed`
    /// payload dictionary. Returns `nil` if the event has no `id` (sentinel
    /// rows from Google's incremental sync sometimes arrive without IDs).
    public static func makeObservedPayload(
        _ event: GoogleCalendarAPI.Event,
        calendar: GoogleCalendarSyncTokenStore.KnownCalendar,
        userDomain: String
    ) -> [String: Any]? {
        guard let eventId = event.id else { return nil }

        let attendeeSummary = summarizeAttendees(event.attendees, userDomain: userDomain)
        let conference = bucketConference(event.conferenceData)

        var payload: [String: Any] = [
            "source": "google_calendar",
            "event_kind": GoogleCalendarEventKind.eventObserved.rawValue,
            "event_id": eventId,
            "calendar_id": calendar.id,
            "calendar_access_role": calendar.accessRole,
            "event_type": bucketEventType(event.eventType),
            "is_all_day": (event.start?.date != nil),
            "attendees_count": attendeeSummary.count,
            "external_attendee_count": attendeeSummary.externalCount,
            "self_is_organizer": (event.organizer?.isSelf == true),
            "self_is_creator": (event.creator?.isSelf == true),
            "is_recurring_instance": (event.recurringEventId != nil),
            "recurrence_frequency_bucket": bucketRecurrence(event.recurrence),
            "conference_entry_point_type": conference.entryPointType,
            "conference_solution_type": conference.solutionType,
        ]

        // Optional keys — only included when source data present.
        if let iCalUID = event.iCalUID { payload["i_cal_uid"] = iCalUID }
        if let status = event.status { payload["status"] = status }
        if let summary = event.summary { payload["summary"] = summary }
        if let startMs = parseTimePointMs(event.start) { payload["start_ms"] = startMs }
        if let endMs = parseTimePointMs(event.end) { payload["end_ms"] = endMs }
        if let tz = event.start?.timeZone ?? event.end?.timeZone { payload["timezone"] = tz }
        if let t = event.transparency { payload["transparency"] = t }
        if let v = event.visibility { payload["visibility"] = v }
        if let selfStatus = attendeeSummary.selfResponseStatus {
            payload["self_response_status"] = selfStatus
        }
        if let createdMs = parseRFC3339Ms(event.created) { payload["created_ms"] = createdMs }
        if let updatedMs = parseRFC3339Ms(event.updated) { payload["updated_ms"] = updatedMs }

        return payload
    }

    // MARK: - Helpers (file-private)

    /// Bucket Google's `eventType` enum. Unknown values (incl. `birthday` /
    /// `fromGmail` which the collector blocklists upstream but might slip
    /// through future API changes) graceful-degrade to `"other"`. Nil →
    /// `"default"` (Google API contract: omitted `eventType` means default).
    fileprivate static func bucketEventType(_ raw: String?) -> String {
        guard let raw else { return "default" }
        switch raw {
        case "default", "focusTime", "outOfOffice", "workingLocation":
            return raw
        default:
            return "other"
        }
    }

    /// Convert a `TimePoint` to epoch-ms. Handles both `dateTime` (RFC3339 with
    /// TZ) and `date` (ISO date for all-day events — midnight UTC).
    ///
    /// `internal`, not `fileprivate`, so `GoogleCalendarCollector` (sibling
    /// module file) can drive tracker UPSERT off the same parser the mapper
    /// uses for payload fields — single source of truth for time semantics.
    internal static func parseTimePointMs(_ tp: GoogleCalendarAPI.TimePoint?) -> Int64? {
        guard let tp else { return nil }
        if let dt = tp.dateTime, let ms = parseRFC3339Ms(dt) { return ms }
        if let d = tp.date, let ms = parseAllDayDateMs(d) { return ms }
        return nil
    }

    /// Summary returned by ``summarizeAttendees(_:userDomain:)``. Promoted
    /// from a 4-tuple to a named struct: the mapper consumes `count`,
    /// `externalCount`, `selfResponseStatus` directly into the payload, and
    /// `selfOptional` is retained for future ShareEventTypeKey gating.
    fileprivate struct AttendeeSummary {
        let count: Int
        let externalCount: Int
        let selfResponseStatus: String?
        let selfOptional: Bool?

        static let empty = Self(
            count: 0, externalCount: 0,
            selfResponseStatus: nil, selfOptional: nil
        )
    }

    /// Walk attendees array. Self-identification via `isSelf == true`.
    /// External counted by case-insensitive domain mismatch with `userDomain`.
    fileprivate static func summarizeAttendees(
        _ attendees: [GoogleCalendarAPI.Attendee]?,
        userDomain: String
    ) -> AttendeeSummary {
        guard let attendees, !attendees.isEmpty else {
            return .empty
        }
        let lowerDomain = userDomain.lowercased()
        var external = 0
        var selfStatus: String? = nil
        var selfOptional: Bool? = nil
        for a in attendees {
            if a.isSelf == true {
                selfStatus = a.responseStatus
                selfOptional = a.optional
            }
            if let email = a.email,
                let at = email.lastIndex(of: "@")
            {
                let domain = email[email.index(after: at)...].lowercased()
                if domain != lowerDomain { external += 1 }
            }
        }
        return AttendeeSummary(
            count: attendees.count,
            externalCount: external,
            selfResponseStatus: selfStatus,
            selfOptional: selfOptional
        )
    }

    /// First `RRULE:` line in `recurrence`; extract `FREQ=` segment.
    fileprivate static func bucketRecurrence(_ recurrence: [String]?) -> String {
        guard let first = recurrence?.first(where: { $0.hasPrefix("RRULE:") }) else {
            return "one_off"
        }
        let body = first.dropFirst("RRULE:".count)
        for component in body.split(separator: ";") {
            let kv = component.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "FREQ" {
                switch kv[1] {
                case "DAILY": return "daily"
                case "WEEKLY": return "weekly"
                case "MONTHLY": return "monthly"
                case "YEARLY": return "yearly"
                default: return "other"
                }
            }
        }
        return "other"
    }

    /// Conference bucketing. Defaults `"none" / "none"` when absent.
    fileprivate static func bucketConference(
        _ cd: GoogleCalendarAPI.ConferenceData?
    ) -> (entryPointType: String, solutionType: String) {
        guard let cd else { return ("none", "none") }
        let entry: String = {
            guard let raw = cd.entryPoints?.first?.entryPointType else { return "none" }
            switch raw {
            case "video", "phone", "sip", "more": return raw
            default: return "more"
            }
        }()
        let solution: String = {
            guard let raw = cd.conferenceSolution?.key?.type else { return "none" }
            switch raw {
            case "hangoutsMeet", "addOn": return raw
            default: return "other"
            }
        }()
        return (entry, solution)
    }

    /// Parse RFC3339 timestamp (with or without fractional seconds) to epoch-ms.
    fileprivate static func parseRFC3339Ms(_ s: String?) -> Int64? {
        guard let s else { return nil }
        if let d = isoFractional.date(from: s) {
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        if let d = isoBasic.date(from: s) {
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        return nil
    }

    /// Parse `YYYY-MM-DD` (all-day) as midnight UTC ms.
    fileprivate static func parseAllDayDateMs(_ s: String) -> Int64? {
        guard let d = allDayFormatter.date(from: s) else { return nil }
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    // Static formatters — Phase 4.7 carry-over discipline (no per-call init).
    // `nonisolated(unsafe)`: configured once at load-time, then read-only —
    // Foundation date formatters are documented thread-safe for `.date(from:)`
    // after configuration is complete (matches `SystemObserversStore.sharedDefaults`
    // / `LocalAppsStore.sharedDefaults` pattern in this package).
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let allDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - Task 7: Transition payloads
//
// 5 clock-driven transition kinds — emitted by the collector's transition
// ticker when a tracked focusTime / outOfOffice block crosses its start or
// end boundary, and when a workingLocation event is first observed (single-
// shot — no paired `_ended`).
//
// Spec §6.3 (transition shapes) + §6.4 (forbidden output keys).
// ADR-010 posture: same as `makeObservedPayload` — the mapper NEVER reads
// `declineMessage` or any workingLocation building/floor/desk/label field;
// Task 3 Codable doesn't even decode the latter set. The privacy walkbacks
// live in the tests (sentinel-string grep on serialised JSON).

extension GoogleCalendarEventMapper {

    /// Direction of a tracked-event boundary crossing. `started` / `ended`
    /// apply to focusTime + outOfOffice (paired). `changed` is the single-
    /// shot phase for workingLocation events.
    public enum TransitionPhase: Sendable {
        case started
        case ended
        case changed
    }

    /// Build a transition payload for a focusTime / outOfOffice / workingLocation
    /// event. Returns `nil` if the `(event.eventType, phase)` combination is
    /// not a valid transition (defensive — unknown / nil eventType, or paired
    /// phase requested for a single-shot event type, etc.).
    public static func makeTransitionPayload(
        event: GoogleCalendarAPI.Event,
        phase: TransitionPhase,
        calendarId: String
    ) -> [String: Any]? {
        guard let eventId = event.id, let eventType = event.eventType else { return nil }
        guard let kind = transitionKind(eventType: eventType, phase: phase) else { return nil }

        var payload: [String: Any] = [
            "source": "google_calendar",
            "event_kind": kind.rawValue,
            "event_id": eventId,
            "calendar_id": calendarId,
        ]
        if let iCalUID = event.iCalUID { payload["i_cal_uid"] = iCalUID }
        if let startMs = parseTimePointMs(event.start) { payload["start_ms"] = startMs }
        if let endMs = parseTimePointMs(event.end) { payload["end_ms"] = endMs }

        if phase == .started {
            applyStartedFieldsFromEvent(event: event, eventType: eventType, payload: &payload)
        }
        if phase == .changed, eventType == "workingLocation",
            let wlType = event.workingLocationProperties?.type
        {
            payload["working_location_type"] = wlType
        }

        return payload
    }

    /// (eventType, phase) → kind. Exhaustive map; anything else returns nil.
    /// Shared between the Event-based and tracker-row-based variants — Task
    /// 6/7 sentinel-walkback tests cover both paths.
    private static func transitionKind(
        eventType: String, phase: TransitionPhase
    ) -> GoogleCalendarEventKind? {
        switch (eventType, phase) {
        case ("focusTime", .started): return .focusBlockStarted
        case ("focusTime", .ended): return .focusBlockEnded
        case ("outOfOffice", .started): return .oooStarted
        case ("outOfOffice", .ended): return .oooEnded
        case ("workingLocation", .changed): return .workingLocationChanged
        default: return nil
        }
    }

    /// Active-phase-only fields from the API Event. autoDeclineMode /
    /// chatStatus describe how the block is configured during its life; on
    /// `_ended` we surface only the boundary itself (operational state has
    /// ceased to be meaningful). OOO has only autoDeclineMode (no chatStatus
    /// per Google API).
    private static func applyStartedFieldsFromEvent(
        event: GoogleCalendarAPI.Event, eventType: String, payload: inout [String: Any]
    ) {
        switch eventType {
        case "focusTime":
            if let mode = event.focusTimeProperties?.autoDeclineMode {
                payload["auto_decline_mode"] = mode
            }
            if let chat = event.focusTimeProperties?.chatStatus {
                payload["chat_status"] = chat
            }
        case "outOfOffice":
            if let mode = event.outOfOfficeProperties?.autoDeclineMode {
                payload["auto_decline_mode"] = mode
            }
        default:
            break
        }
    }

    /// Track-6 P4 Task 14 — build a transition payload directly from a tracker
    /// row. Used by `GoogleCalendarCollector` at the end of each tick when
    /// scanning M027 for time-crossings — the full `Event` is no longer in
    /// memory at that point, but the tracker row carries every field we need
    /// to rebuild the same payload shape that
    /// `makeTransitionPayload(event:phase:calendarId:)` would emit at observe
    /// time.
    ///
    /// **Shape parity:** payloads produced by this method must match the
    /// Event-based variant key-for-key for the same logical inputs — Task
    /// 6/7 sentinel-walkback tests cover both paths. ADR-010 holds by
    /// construction: tracker row only carries structural enum buckets
    /// (`autoDeclineMode` / `chatStatus` / `workingLocationType`) — no
    /// description / location / declineMessage / attendee data ever reach
    /// the tracker, so they cannot leak through this codepath.
    public static func makeTransitionPayload(
        fromTrackerRow row: GoogleCalendarTrackerStore.Row,
        phase: TransitionPhase
    ) -> [String: Any]? {
        guard let kind = transitionKind(eventType: row.eventType, phase: phase) else {
            return nil
        }

        var payload: [String: Any] = [
            "source": "google_calendar",
            "event_kind": kind.rawValue,
            "event_id": row.eventID,
            "calendar_id": row.calendarID,
            "start_ms": row.startMs,
            "end_ms": row.endMs,
        ]
        if let iCalUID = row.iCalUID { payload["i_cal_uid"] = iCalUID }

        if phase == .started {
            applyStartedFieldsFromTracker(row: row, payload: &payload)
        }
        if phase == .changed, row.eventType == "workingLocation",
            let wl = row.workingLocationType
        {
            payload["working_location_type"] = wl
        }

        return payload
    }

    /// Active-phase-only fields from the tracker row. Mirrors the Event-based
    /// variant — on `_ended` we surface only the boundary itself; operational
    /// state (`auto_decline_mode` / `chat_status`) is no longer meaningful.
    private static func applyStartedFieldsFromTracker(
        row: GoogleCalendarTrackerStore.Row, payload: inout [String: Any]
    ) {
        switch row.eventType {
        case "focusTime":
            if let mode = row.autoDeclineMode { payload["auto_decline_mode"] = mode }
            if let chat = row.chatStatus { payload["chat_status"] = chat }
        case "outOfOffice":
            if let mode = row.autoDeclineMode { payload["auto_decline_mode"] = mode }
        default:
            break
        }
    }
}
