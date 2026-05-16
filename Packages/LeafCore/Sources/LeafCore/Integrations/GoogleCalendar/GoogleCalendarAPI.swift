import Foundation

/// Track-6 P4 — Google Calendar API v3 Codable shapes. Decode-only for MVP
/// (we never POST event data). Spec §6.3 + research doc §1.4 list every
/// field captured; this file decodes a superset — privacy filtering is
/// `GoogleCalendarEventMapper`'s job (Task 6+7).
///
/// ADR-010 posture: some fields below are decoded into Swift structs but
/// MUST NOT be written into stored `payload_json`. Mapper enforces walkbacks.
/// Comments mark each such field with `// decoded; Mapper drops (ADR-010).`
///
/// INTENTIONALLY NOT DECODED (so the values can't even leak via debug-print):
/// - `ConferenceData.EntryPoint.uri` (the actual Meet/Zoom join link)
/// - `ConferenceData.EntryPoint.pin` / `accessCode` / `password` / `passcode` / `meetingCode`
/// - `WorkingLocationProperties.officeLocation.{buildingId,floorId,deskId,label}`
/// - `WorkingLocationProperties.customLocation.label`
public enum GoogleCalendarAPI {

    // MARK: - List responses

    public struct EventsListResponse: Codable, Sendable {
        public let kind: String?
        public let summary: String?
        public let timeZone: String?
        public let accessRole: String?
        public let items: [Event]
        public let nextPageToken: String?
        public let nextSyncToken: String?
    }

    public struct CalendarListResponse: Codable, Sendable {
        public let items: [CalendarListEntry]
        public let nextPageToken: String?
        public let nextSyncToken: String?
    }

    public struct CalendarListEntry: Codable, Sendable {
        public let id: String
        public let summary: String?
        public let summaryOverride: String?
        public let primary: Bool?
        public let accessRole: String      // owner | writer | reader | freeBusyReader
        public let timeZone: String?
        public let colorId: String?
    }

    // MARK: - Event

    public struct Event: Codable, Sendable {
        public let id: String?
        public let iCalUID: String?
        public let status: String?                 // confirmed | tentative | cancelled
        public let summary: String?
        public let description: String?            // decoded; Mapper drops (ADR-010).
        public let location: String?               // decoded; Mapper drops (ADR-010).
        public let start: TimePoint?
        public let end: TimePoint?
        public let recurrence: [String]?
        public let recurringEventId: String?
        public let originalStartTime: TimePoint?
        public let attendees: [Attendee]?
        public let organizer: Person?
        public let creator: Person?
        public let eventType: String?              // default | focusTime | outOfOffice | workingLocation | birthday | fromGmail
        public let transparency: String?
        public let visibility: String?
        public let conferenceData: ConferenceData?
        public let focusTimeProperties: FocusTimeProperties?
        public let outOfOfficeProperties: OutOfOfficeProperties?
        public let workingLocationProperties: WorkingLocationProperties?
        public let created: String?
        public let updated: String?
        public let htmlLink: String?               // decoded; Mapper drops (ADR-010).
    }

    public struct TimePoint: Codable, Sendable {
        public let dateTime: String?
        public let date: String?
        public let timeZone: String?
    }

    public struct Person: Codable, Sendable {
        public let email: String?
        public let displayName: String?
        public let isSelf: Bool?

        // `self` is a Swift keyword — map to `isSelf` for usable property name.
        private enum CodingKeys: String, CodingKey {
            case email
            case displayName
            case isSelf = "self"
        }
    }

    public struct Attendee: Codable, Sendable {
        public let email: String?
        public let displayName: String?
        public let isSelf: Bool?
        public let responseStatus: String?
        public let optional: Bool?
        public let organizer: Bool?

        private enum CodingKeys: String, CodingKey {
            case email
            case displayName
            case isSelf = "self"
            case responseStatus
            case optional
            case organizer
        }
    }

    // MARK: - Conference data (privacy-clipped)

    public struct ConferenceData: Codable, Sendable {
        public let entryPoints: [EntryPoint]?
        public let conferenceSolution: ConferenceSolution?

        /// Privacy posture: only `entryPointType` is decoded.
        /// `uri`, `pin`, `accessCode`, `password`, `passcode`, `meetingCode`
        /// are INTENTIONALLY NOT DECODED — we never want these values in
        /// memory (can leak via debug-print, crash logs, etc.).
        public struct EntryPoint: Codable, Sendable {
            public let entryPointType: String?     // video | phone | sip | more
        }

        public struct ConferenceSolution: Codable, Sendable {
            public let key: Key?

            public struct Key: Codable, Sendable {
                public let type: String?           // hangoutsMeet | addOn | etc.
            }
        }
    }

    // MARK: - Type-specific event properties

    public struct FocusTimeProperties: Codable, Sendable {
        public let autoDeclineMode: String?
        public let declineMessage: String?         // decoded; Mapper drops (ADR-010).
        public let chatStatus: String?
    }

    public struct OutOfOfficeProperties: Codable, Sendable {
        public let autoDeclineMode: String?
        public let declineMessage: String?         // decoded; Mapper drops (ADR-010).
    }

    /// Privacy posture: only `type` enum is decoded.
    /// `officeLocation.{buildingId,floorId,deskId,label}` and
    /// `customLocation.label` are INTENTIONALLY NOT DECODED — physical
    /// location specifics never enter the in-memory model.
    public struct WorkingLocationProperties: Codable, Sendable {
        public let type: String?                   // homeOffice | officeLocation | customLocation
    }

    // MARK: - OAuth

    public struct TokenResponse: Codable, Sendable {
        public let accessToken: String
        public let expiresIn: Int
        public let refreshToken: String?
        public let scope: String?
        public let tokenType: String?

        // Google's token endpoint speaks snake_case; map to Swift camelCase.
        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
            case tokenType = "token_type"
        }
    }

    // MARK: - Error envelope

    public struct ErrorEnvelope: Codable, Sendable {
        public let error: Body

        public struct Body: Codable, Sendable {
            public let code: Int
            public let message: String?
            public let errors: [Detail]?

            public struct Detail: Codable, Sendable {
                public let reason: String?
                public let domain: String?
            }
        }
    }
}
