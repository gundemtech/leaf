import Foundation
import CoreGraphics
import os
import LeafCore

/// Phase Track-4 S3 — CoreGraphics `CGDisplayRegisterReconfigurationCallback`.
/// Filters `CGDisplayChangeSummaryFlags` — emits ONLY на `.addFlag`
/// (→ display_connected) или `.removeFlag` (→ display_disconnected).
/// Ignores `.modeChangedFlag` / `.setMainFlag` / `.rotationFlag` (noise).
///
/// **NEVER** calls CGDisplayCreateImage / CGWindowListCreateImage /
/// ScreenCaptureKit (ADR-010 Won't-list — display → boolean only, no pixels).
@MainActor
final class DisplayCollector {
    private let writer: EventWriter
    private let observersStore: SystemObserversStore
    private var stateMachine = DisplayStateMachine()
    private var registered = false

    // Static singleton — production runtime has exactly one DisplayCollector
    // (Agent.main constructs once + retains в AgentLifetime). The static
    // reference is the C-callback fan-out target since
    // `CGDisplayRegisterReconfigurationCallback` takes `userInfo:` arg
    // that maps awkwardly to Swift refcon-pattern. **Test isolation
    // limitation (I3 review):** unit tests cannot instantiate two
    // collectors back-to-back without `stop()` between (would orphan
    // the prior instance reference). Production constraint — fine.
    private static var sharedInstance: DisplayCollector?

    init(writer: EventWriter, observersStore: SystemObserversStore) {
        self.writer = writer
        self.observersStore = observersStore
    }

    func start() async {
        guard observersStore.isEnabled("display") else {
            collectorLogger.info("DisplayCollector disabled by master toggle")
            return
        }
        Self.sharedInstance = self
        let status = CGDisplayRegisterReconfigurationCallback(
            DisplayCollector.reconfigCallback,
            nil
        )
        if status == .success {
            registered = true
            collectorLogger.info("DisplayCollector started")
        } else {
            collectorLogger.error("CGDisplayRegisterReconfigurationCallback failed status=\(status.rawValue, privacy: .public)")
        }
    }

    func stop() async {
        if registered {
            _ = CGDisplayRemoveReconfigurationCallback(
                DisplayCollector.reconfigCallback,
                nil
            )
            registered = false
        }
        Self.sharedInstance = nil
        collectorLogger.info("DisplayCollector stopped")
    }

    fileprivate func handleReconfiguration(
        displayID: CGDirectDisplayID,
        flags: CGDisplayChangeSummaryFlags
    ) {
        let change: DisplayChange?
        if flags.contains(.addFlag) {
            change = DisplayChange(displayId: UInt32(displayID), kind: .connected)
        } else if flags.contains(.removeFlag) {
            change = DisplayChange(displayId: UInt32(displayID), kind: .disconnected)
        } else {
            change = nil
        }
        guard let change else { return }
        guard let transition = stateMachine.observe(change) else { return }
        let eventKind: String
        let state: String
        switch transition {
        case .connected:    eventKind = "display_connected";    state = "display_connected"
        case .disconnected: eventKind = "display_disconnected"; state = "display_disconnected"
        }
        let writer = self.writer
        Task {
            await writer.enqueue(RawEvent(
                signalType: .context,
                bundleID: nil,
                payload: ["event_kind": eventKind, "state": state]
            ))
        }
        collectorLogger.info("Display transition -> \(eventKind, privacy: .public)")
    }

    // C-style callback signature — captures via Self.sharedInstance pointer.
    private static let reconfigCallback: CGDisplayReconfigurationCallBack = { displayID, flags, _ in
        guard let instance = DisplayCollector.sharedInstance else { return }
        MainActor.assumeIsolated {
            instance.handleReconfiguration(displayID: displayID, flags: flags)
        }
    }
}
