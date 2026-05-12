import Foundation
import EventKit
import os
import LeafCore

/// Phase Track-4 S1 — Layer A catch-up. Translates the current `EKEventStore`
/// view of the user's calendars into a single `MeetingObservation` boolean
/// (`isInMeeting`), feeds it through `MeetingStateMachine`, and emits
/// `meeting_state_entered` / `meeting_state_exited` on transitions. NEVER
/// reads event.title / .location / .attendees / .notes / .url / .organizer
/// (privacy boundary — guarded by S1CollectorSourceGrepTests).
final class CalendarCollector: @unchecked Sendable {
    private let writer: EventWriter
    private let store: EKEventStore
    private let pollIntervalSec: TimeInterval
    private var machine = MeetingStateMachine()
    private var pollTask: Task<Void, Never>?
    private var storeChangedObserver: NSObjectProtocol?
    private var granted = false

    init(writer: EventWriter, pollIntervalSec: TimeInterval) {
        self.writer = writer
        self.store = EKEventStore()
        self.pollIntervalSec = pollIntervalSec
    }

    func start() async {
        let granted: Bool
        if #available(macOS 14.0, *) {
            do {
                granted = try await store.requestFullAccessToEvents()
            } catch {
                collectorLogger.error("CalendarCollector requestFullAccessToEvents failed: \(error.localizedDescription, privacy: .public)")
                granted = false
            }
        } else {
            granted = false
        }
        self.granted = granted
        if !granted {
            collectorLogger.info("CalendarCollector — permission not granted; collector idle")
            return
        }
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.tick() }
        }
        let intervalNs = UInt64(pollIntervalSec * 1_000_000_000)
        let interval = pollIntervalSec
        pollTask = Task { [weak self] in
            collectorLogger.info("CalendarCollector started (poll=\(interval, privacy: .public)s)")
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    func stop() async {
        if let observer = storeChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        storeChangedObserver = nil
        pollTask?.cancel()
        pollTask = nil
        collectorLogger.info("CalendarCollector stopped")
    }

    private func tick() async {
        guard granted else { return }
        let now = Date()
        let windowStart = now.addingTimeInterval(-300)
        let predicate = store.predicateForEvents(withStart: windowStart, end: now, calendars: nil)
        let events = store.events(matching: predicate)
        let isInMeeting = events.contains { item in
            // Boundary reads ONLY .startDate / .endDate / .isAllDay / .status —
            // guarded by S1CollectorSourceGrepTests.
            !item.isAllDay
                && item.status != .canceled
                && item.startDate <= now
                && item.endDate > now
        }
        let observation = MeetingObservation(isInMeeting: isInMeeting)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        guard let transition = machine.observe(observation, nowMs: nowMs) else { return }
        let eventKind: String
        let state: String
        switch transition {
        case .entered:
            eventKind = "meeting_state_entered"
            state = "in_meeting"
        case .exited:
            eventKind = "meeting_state_exited"
            state = "not_in_meeting"
        }
        let raw = RawEvent(
            signalType: .context,
            bundleID: nil,
            payload: ["event_kind": eventKind, "state": state]
        )
        await writer.enqueue(raw)
        collectorLogger.info("Meeting transition -> \(eventKind, privacy: .public)")
    }
}
