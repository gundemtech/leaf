import Foundation
import Intents
import LeafCore
import os

/// Phase Track-4 S1 — Layer A catch-up. Polls
/// `INFocusStatusCenter.default.focusStatus.isFocused` and emits
/// `focus_mode_enabled` / `focus_mode_disabled` on transitions. macOS public
/// API exposes only the boolean (no mode name) — boolean-only observation by
/// design.
final class FocusModeCollector: @unchecked Sendable {
    private let writer: EventWriter
    private let pollIntervalSec: TimeInterval
    private var machine = FocusStateMachine()
    private var pollTask: Task<Void, Never>?
    private var granted = false

    init(writer: EventWriter, pollIntervalSec: TimeInterval) {
        self.writer = writer
        self.pollIntervalSec = pollIntervalSec
    }

    func start() async {
        let granted: Bool = await withCheckedContinuation { cont in
            INFocusStatusCenter.default.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        self.granted = granted
        if !granted {
            collectorLogger.info("FocusModeCollector — permission not granted; collector idle")
            return
        }
        let intervalNs = UInt64(pollIntervalSec * 1_000_000_000)
        let interval = pollIntervalSec
        pollTask = Task { [weak self] in
            collectorLogger.info("FocusModeCollector started (poll=\(interval, privacy: .public)s)")
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        collectorLogger.info("FocusModeCollector stopped")
    }

    private func tick() async {
        guard granted else { return }
        // Boundary reads ONLY .isFocused — guarded by
        // S1CollectorSourceGrepTests.
        let isFocused = INFocusStatusCenter.default.focusStatus.isFocused ?? false
        let observation = FocusObservation(isFocused: isFocused)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard let transition = machine.observe(observation, nowMs: nowMs) else { return }
        let eventKind: String
        let state: String
        switch transition {
        case .enabled:
            eventKind = "focus_mode_enabled"
            state = "focused"
        case .disabled:
            eventKind = "focus_mode_disabled"
            state = "not_focused"
        }
        let raw = RawEvent(
            signalType: .context,
            bundleID: nil,
            payload: ["event_kind": eventKind, "state": state]
        )
        await writer.enqueue(raw)
        collectorLogger.info("Focus transition -> \(eventKind, privacy: .public)")
    }
}
