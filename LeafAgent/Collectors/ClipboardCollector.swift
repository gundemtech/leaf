import AppKit
import Foundation
import LeafCore
import os

/// Phase Track-4 S3 — `NSPasteboard.general.changeCount` delta polling.
/// Emits ONE `clipboard_event_count` per tick if `delta > 0`.
///
/// **NEVER** reads `pasteboardItems` / `string(forType:)` / `data(forType:)` /
/// `propertyList` — only the numeric changeCount (ADR-010 Won't-list —
/// clipboard → count only).
@MainActor
final class ClipboardCollector {
    private let writer: EventWriter
    private let observersStore: SystemObserversStore
    private let pollIntervalSec: TimeInterval
    private var stateMachine = ClipboardCounterStateMachine()
    private var pollTask: Task<Void, Never>?

    init(
        writer: EventWriter,
        observersStore: SystemObserversStore,
        pollIntervalSec: TimeInterval
    ) {
        self.writer = writer
        self.observersStore = observersStore
        self.pollIntervalSec = pollIntervalSec
    }

    func start() async {
        guard observersStore.isEnabled("clipboard") else {
            collectorLogger.info("ClipboardCollector disabled by master toggle")
            return
        }
        let intervalNs = UInt64(pollIntervalSec * 1_000_000_000)
        let interval = pollIntervalSec
        // Seed lastCount with current changeCount (no emit на first observation).
        _ = stateMachine.observe(NSPasteboard.general.changeCount)
        pollTask = Task { [weak self] in
            collectorLogger.info("ClipboardCollector started (poll=\(interval, privacy: .public)s)")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { break }
                await self?.tickOnce()
            }
        }
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        collectorLogger.info("ClipboardCollector stopped")
    }

    private func tickOnce() async {
        // Boundary reads ONLY changeCount — numeric monotonic counter.
        let count = NSPasteboard.general.changeCount
        guard let delta = stateMachine.observe(count), delta > 0 else { return }
        let raw = RawEvent(
            signalType: .context,
            bundleID: nil,
            payload: [
                "event_kind": "clipboard_event_count",
                "count": String(delta),
            ]
        )
        await writer.enqueue(raw)
        collectorLogger.info("Clipboard delta=\(delta, privacy: .public)")
    }
}
