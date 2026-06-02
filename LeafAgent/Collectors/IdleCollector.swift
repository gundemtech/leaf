import Foundation
import CoreGraphics
import os
import LeafCore

/// Polls `CGEventSource` for the time of the last HID event.
/// Writes context events only on active↔idle transitions — not on every tick.
final class IdleCollector: @unchecked Sendable {
    private let writer: EventWriter
    private let thresholds: AgentThresholds
    private var task: Task<Void, Never>?
    private var isIdle = false

    init(writer: EventWriter, thresholds: AgentThresholds) {
        self.writer = writer
        self.thresholds = thresholds
    }

    func start() {
        let writer = self.writer
        let pollInterval = thresholds.idlePollIntervalSec
        let idleThreshold = thresholds.idleThresholdSec

        task = Task { [weak self] in
            collectorLogger.info("IdleCollector started")
            while !Task.isCancelled {
                self?.tick(writer: writer, idleThreshold: idleThreshold, pollInterval: pollInterval)
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        collectorLogger.info("IdleCollector stopped")
    }

    private func tick(writer: EventWriter, idleThreshold: TimeInterval, pollInterval: TimeInterval) {
        // Any HID event (kCGAnyInputEventType == rawValue ~0)
        let anyEventType = CGEventType(rawValue: ~0) ?? .null
        let idleSec = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEventType)

        let nowIdle = idleSec > idleThreshold
        guard nowIdle != isIdle else { return }

        isIdle = nowIdle
        let state = nowIdle ? "idle" : "active"
        let event = RawEvent(
            signalType: .context,
            bundleID: nil,
            payload: ["state": state]
        )
        Task { await writer.enqueue(event) }
        collectorLogger.info("Presence transition -> \(state, privacy: .public)")
    }
}
