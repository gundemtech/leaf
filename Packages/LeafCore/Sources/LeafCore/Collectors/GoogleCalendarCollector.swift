//
//  GoogleCalendarCollector.swift
//  LeafCore
//
//  Track-6 P4 Task 13 — Google Calendar v3 polling collector.
//  Bootstrap + steady-state events.list sync per spec §8.2.
//  No transitions yet (Task 14), no presence_state writes (Task 16).
//
//  Tick flow:
//    1. Read IntegrationRecord (skip silently if absent).
//    2. Proactive token refresh; .invalidGrant → .reconnectNeeded.
//    3. Every Nth tick (default 12 = ~1h on 5m cadence) + first tick after
//       connect: calendarList sync (walk pages on initial fetch, diff vs
//       knownCalendars, prune deletions).
//    4. Per known calendar: pull events.list pages until terminal
//       (nextPageToken == nil). On terminal page persist nextSyncToken +
//       clear bootstrapInProgress. On 410 → drop calendar token + tracker
//       rows, retry next tick. On 401 → reactive refresh + retry once.
//    5. Emit one `google_calendar_event_observed` row per non-blocklisted
//       event. UPSERT tracker for focusTime/outOfOffice/workingLocation;
//       DELETE tracker on status="cancelled".
//    6. Cleanup tracker rows older than 7d.
//
//  ADR-010 boundary: payloads built by `GoogleCalendarEventMapper` (which
//  drops description/location/attendee PII/declineMessage etc). The
//  collector only converts the mapper's Any-typed dict into the
//  RawEvent string-string payload shape — no body fields leak through here.
//
//  Phase 2.3.C.3 split — `tick` + transition scan + presence_state write
//  live in `GoogleCalendarCollector+Tick.swift`; calendarList + per-calendar
//  events.list sync + page processing in `GoogleCalendarCollector+Sync.swift`;
//  pure helpers (domain extract / payload flatten / anchor timestamp) in
//  `GoogleCalendarCollector+Helpers.swift`.
//

import Foundation
import GRDB
import os

/// Track-6 P4 Task 13 — Google Calendar polling collector.
///
/// Mirrors LinearCollector at the high level (read integration → refresh →
/// fetch → emit events → persist cursor) but uses per-calendar syncToken
/// cursors in `provider_snapshots` rather than the `collector_offsets` row
/// pattern (Google's sync semantics is per-calendar, not a single global
/// updatedAt watermark).
public actor GoogleCalendarCollector {

    /// Bundle IDs Google emits that we do not want to surface as work events.
    /// `fromGmail` = auto-extracted bookings from email; `birthday` = the
    /// virtual Contacts birthdays calendar entries. Filter applies BEFORE
    /// mapper to avoid building/discarding payloads downstream.
    public static let eventTypeBlocklist: Set<String> = ["fromGmail", "birthday"]

    /// Bootstrap window — how far back the first sweep reaches. 365 days
    /// gives Derived Insights enough history to compute month-over-month
    /// without dragging in distant low-value past entries.
    static let bootstrapWindowSec: TimeInterval = 365 * 24 * 3600

    /// Tracker cleanup horizon. Rows whose `end_ms` is older than this are
    /// dropped on every tick — they can no longer drive any "currently
    /// active" presence-state query.
    static let trackerRetentionSec: TimeInterval = 7 * 24 * 3600

    /// AccessRole values we treat as a "real" calendar to sync. `freeBusyReader`
    /// is excluded — no event bodies/metadata available there anyway.
    static let syncableAccessRoles: Set<String> = ["owner", "writer", "reader"]

    public enum TickError: Error, Sendable {
        /// Refresh token rejected with `invalid_grant` (revoked / 7-day testing
        /// expiry / scope change). Caller transitions ConnectionState to
        /// `.reconnectNeeded` per spec §7.5.
        case reconnectNeeded
    }

    let apiClient: GoogleCalendarAPIClient
    let tokenRefresher: GoogleCalendarTokenRefresher
    let database: Database
    let clock: @Sendable () -> Date
    let pollIntervalSec: TimeInterval
    let calendarListEveryNTicks: Int
    let logger: Logger

    private var tickCounter: Int = 0
    private var loopTask: Task<Void, Never>?

    public init(
        apiClient: GoogleCalendarAPIClient,
        tokenRefresher: GoogleCalendarTokenRefresher,
        database: Database,
        clock: @escaping @Sendable () -> Date = { Date() },
        pollIntervalSec: TimeInterval = 300,
        calendarListEveryNTicks: Int = 12,
        logger: Logger = Logger(subsystem: "tech.gundem.leaf", category: "google-calendar-collector")
    ) {
        self.apiClient = apiClient
        self.tokenRefresher = tokenRefresher
        self.database = database
        self.clock = clock
        self.pollIntervalSec = pollIntervalSec
        self.calendarListEveryNTicks = calendarListEveryNTicks
        self.logger = logger
    }

    /// Long-running loop. Cancel via the returned Task or by calling `stop()`.
    public func start() async {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
        logger.info("GoogleCalendarCollector started (interval=\(self.pollIntervalSec, privacy: .public)s)")
    }

    public func stop() async {
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
    }

    private func runLoop() async {
        await sleep(seconds: min(pollIntervalSec, 5))
        while !Task.isCancelled {
            do {
                _ = try await tick()
            } catch TickError.reconnectNeeded {
                logger.warning("tick aborted — reconnect needed; will retry next tick")
            } catch {
                logger.error("tick failed: \(String(describing: error), privacy: .public)")
            }
            await sleep(seconds: pollIntervalSec)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Tick-counter mutator. Extensions cannot write `private` actor state,
    /// so the +Tick extension calls this thin actor-internal mutator.
    func bumpTickCounter() {
        tickCounter += 1
    }

    /// First-tick + every-Nth-tick gate for calendarList sync, evaluated
    /// after `bumpTickCounter()` is called. Counter sequence is 1, 2, 3 …;
    /// the modulo expression matches tickCounter values 1, 13, 25, … so the
    /// first tick after process start always triggers the sync.
    func shouldRunCalendarListSync() -> Bool {
        tickCounter % calendarListEveryNTicks == 1
    }

    // MARK: - Refresh helpers

    func readIntegrationSafely() throws -> IntegrationRecord? {
        do {
            return try database.readIntegration(provider: .googleCalendar)
        } catch {
            logger.error("readIntegration failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Run a proactive refresh and persist the new token if Google rotated it.
    /// `.invalidGrant` propagates as `.reconnectNeeded`. Returns the
    /// IntegrationRecord that callers should use for the rest of this tick
    /// (either unchanged on `.notDue`, or rebuilt on `.refreshed`).
    func proactiveRefresh(record: IntegrationRecord) async throws -> IntegrationRecord {
        guard let refreshToken = record.refreshToken else {
            // Long-lived assumption — Google docs say refresh_token always
            // returned on first consent; missing here means data corruption
            // or pre-refresh-storage legacy state. Skip refresh, let any
            // 401 fall through to reactive path.
            return record
        }
        let nowMs = Int64(clock().timeIntervalSince1970 * 1000)
        let outcome = try await tokenRefresher.refreshIfDueProactive(
            currentAccessToken: record.accessToken,
            currentRefreshToken: refreshToken,
            currentExpiresAtMs: record.expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            nowMs: nowMs
        )
        switch outcome {
        case .notDue:
            return record
        case .refreshed(let accessToken, let expiresAtMs, let rotatedRefreshToken):
            return try persistRefreshed(
                record: record,
                accessToken: accessToken,
                expiresAtMs: expiresAtMs,
                rotatedRefreshToken: rotatedRefreshToken
            )
        case .invalidGrant:
            throw TickError.reconnectNeeded
        }
    }

    /// Reactive refresh after a 401. Same outcome shape as proactive minus
    /// `.notDue`. Returns the rebuilt record on success, nil on `.invalidGrant`
    /// (which transitions tick to .reconnectNeeded via re-throw).
    func reactiveRefresh(record: IntegrationRecord) async throws -> IntegrationRecord {
        guard let refreshToken = record.refreshToken else {
            throw TickError.reconnectNeeded
        }
        let nowMs = Int64(clock().timeIntervalSince1970 * 1000)
        let outcome = try await tokenRefresher.refreshOn401(
            currentRefreshToken: refreshToken,
            nowMs: nowMs
        )
        switch outcome {
        case .refreshed(let accessToken, let expiresAtMs, let rotatedRefreshToken):
            return try persistRefreshed(
                record: record,
                accessToken: accessToken,
                expiresAtMs: expiresAtMs,
                rotatedRefreshToken: rotatedRefreshToken
            )
        case .invalidGrant:
            throw TickError.reconnectNeeded
        case .notDue:
            // Refresher should never return `.notDue` from refreshOn401 —
            // defensive fall-through. Return the original record.
            return record
        }
    }

    private func persistRefreshed(
        record: IntegrationRecord,
        accessToken: String,
        expiresAtMs: Int64,
        rotatedRefreshToken: String?
    ) throws -> IntegrationRecord {
        let now = clock()
        let updated = IntegrationRecord(
            provider: record.provider,
            workspaceID: record.workspaceID,
            workspaceName: record.workspaceName,
            accessToken: accessToken,
            // Google MAY omit refresh_token on rotation — preserve previous.
            refreshToken: rotatedRefreshToken ?? record.refreshToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1000.0),
            scope: record.scope,
            connectedAt: record.connectedAt,
            updatedAt: now
        )
        try database.upsertIntegration(updated)
        return updated
    }
}
