import AppKit
import Foundation
import LeafCore
import os

/// Phase Track-4 S1 — Layer A catch-up. Subscribes to
/// `NSWorkspace.activeSpaceDidChangeNotification` and emits `space_switched`
/// events. Drops emissions inside the `coalesceWindowMs` window (collapses
/// rapid Mission-Control sweeps). NEVER captures space identifier or name —
/// guarded by S1CollectorSourceGrepTests.
@MainActor
final class SpacesCollector {
    private let writer: EventWriter
    private var coalescer: SpaceTransitionCoalescer
    private var observer: NSObjectProtocol?

    init(writer: EventWriter, coalesceWindowSec: TimeInterval) {
        self.writer = writer
        self.coalescer = SpaceTransitionCoalescer(coalesceWindowMs: Int64(coalesceWindowSec * 1000))
    }

    func start() {
        let writer = self.writer
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                guard self.coalescer.observe(nowMs: nowMs) else { return }
                let raw = RawEvent(
                    signalType: .context,
                    bundleID: nil,
                    payload: ["event_kind": "space_switched"]
                )
                Task { await writer.enqueue(raw) }
                collectorLogger.info("Space switched")
            }
        }
        collectorLogger.info("SpacesCollector started")
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        collectorLogger.info("SpacesCollector stopped")
    }
}
