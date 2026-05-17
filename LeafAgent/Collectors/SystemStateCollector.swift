import AppKit
import Foundation
import LeafCore
import os

/// Phase Track-4 S1 — Layer A catch-up. Subscribes to
/// `DistributedNotificationCenter` for `com.apple.screenIsLocked` /
/// `com.apple.screenIsUnlocked` + NSWorkspace `willSleep` / `didWake` and
/// emits `system_locked` / `system_unlocked` / `system_slept` / `system_woke`
/// transitions. Exposes `isLocked` / `isSleeping` read-only state for future
/// S3 CGEventTap consumer (CGEventTap must drop while system locked /
/// sleeping per won't-list). Collector is MainActor-isolated — all observer
/// callbacks fire on main queue (`queue: .main`), so state mutation is
/// inherently serialised.
@MainActor
final class SystemStateCollector {
    private let writer: EventWriter
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private(set) var isLocked = false
    private(set) var isSleeping = false

    init(writer: EventWriter) {
        self.writer = writer
    }

    func start() {
        let writer = self.writer
        let dnc = DistributedNotificationCenter.default()
        observers.append(
            dnc.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLocked = true
                    self?.emit(eventKind: "system_locked", writer: writer)
                }
            })
        observers.append(
            dnc.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLocked = false
                    self?.emit(eventKind: "system_unlocked", writer: writer)
                }
            })
        let wsnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            wsnc.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSleeping = true
                    self?.emit(eventKind: "system_slept", writer: writer)
                }
            })
        workspaceObservers.append(
            wsnc.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSleeping = false
                    self?.emit(eventKind: "system_woke", writer: writer)
                }
            })
        collectorLogger.info("SystemStateCollector started")
    }

    func stop() {
        let dnc = DistributedNotificationCenter.default()
        for o in observers { dnc.removeObserver(o) }
        observers.removeAll()
        let wsnc = NSWorkspace.shared.notificationCenter
        for o in workspaceObservers { wsnc.removeObserver(o) }
        workspaceObservers.removeAll()
        collectorLogger.info("SystemStateCollector stopped")
    }

    private func emit(eventKind: String, writer: EventWriter) {
        let raw = RawEvent(
            signalType: .context,
            bundleID: nil,
            payload: ["event_kind": eventKind]
        )
        Task { await writer.enqueue(raw) }
        collectorLogger.info("System transition -> \(eventKind, privacy: .public)")
    }
}
