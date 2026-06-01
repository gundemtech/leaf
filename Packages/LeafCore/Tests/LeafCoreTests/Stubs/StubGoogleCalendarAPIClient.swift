// Track-6 P4 Task 11 — test stub for GoogleCalendarAPIClient.
// Actor-isolated so test setup (enqueue) + concurrent collector calls compose
// without Sendable ceremony. Call-log lets per-test assertions verify which
// path the collector took (bootstrap vs subsequent vs primary lookup).

import Foundation

@testable import LeafCore

public actor StubGoogleCalendarAPIClient: GoogleCalendarAPIClient {

    private var eventsListQueue: [GoogleCalendarAPI.EventsListResponse] = []
    private var calendarListQueue: [GoogleCalendarAPI.CalendarListResponse] = []
    private var primaryResponse: GoogleCalendarAPI.CalendarListEntry?
    private var eventsListError: GoogleCalendarAPIError?
    private var callLog: [String] = []

    public init() {}

    // MARK: - Test setup

    public func enqueueEventsList(_ response: GoogleCalendarAPI.EventsListResponse) {
        eventsListQueue.append(response)
    }

    public func enqueueCalendarList(_ response: GoogleCalendarAPI.CalendarListResponse) {
        calendarListQueue.append(response)
    }

    public func setPrimary(_ entry: GoogleCalendarAPI.CalendarListEntry) {
        primaryResponse = entry
    }

    public func setEventsListError(_ error: GoogleCalendarAPIError?) {
        eventsListError = error
    }

    public func calls() -> [String] { callLog }

    // MARK: - Protocol conformance

    public func eventsList(
        calendarID: String,
        syncToken: String?,
        bootstrapTimeMin: Date?,
        pageToken: String?,
        accessToken: String
    ) async throws -> GoogleCalendarAPI.EventsListResponse {
        callLog.append("eventsList(\(calendarID), syncToken=\(syncToken ?? "nil"), pageToken=\(pageToken ?? "nil"))")
        if let error = eventsListError { throw error }
        guard !eventsListQueue.isEmpty else {
            fatalError("StubGoogleCalendarAPIClient.eventsList queue empty")
        }
        return eventsListQueue.removeFirst()
    }

    public func calendarListList(
        syncToken: String?,
        pageToken: String?,
        accessToken: String
    ) async throws -> GoogleCalendarAPI.CalendarListResponse {
        callLog.append("calendarListList(syncToken=\(syncToken ?? "nil"), pageToken=\(pageToken ?? "nil"))")
        guard !calendarListQueue.isEmpty else {
            fatalError("StubGoogleCalendarAPIClient.calendarListList queue empty")
        }
        return calendarListQueue.removeFirst()
    }

    public func calendarListGetPrimary(
        accessToken: String
    ) async throws -> GoogleCalendarAPI.CalendarListEntry {
        callLog.append("calendarListGetPrimary")
        guard let p = primaryResponse else {
            fatalError("StubGoogleCalendarAPIClient.primaryResponse not set")
        }
        return p
    }
}
