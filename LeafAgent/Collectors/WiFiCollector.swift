import Foundation
import CoreWLAN
import os
import LeafCore

/// Phase Track-4 S3 — `CWWiFiClient.shared().interface()` polling, state only.
///
/// **NO SSID capture.** Reads only `CWInterface.interfaceMode` (UInt32 —
/// .none / .station / .ibss / .hostAP) and `CWInterface.powerOn() -> Bool`.
/// SSID PII concern eliminated + Location TCC prompt avoided (CWInterface.ssid()
/// returns nil without Location TCC; we never call it) — ADR-010 Won't-list.
@MainActor
final class WiFiCollector {
    private let writer: EventWriter
    private let observersStore: SystemObserversStore
    private let pollIntervalSec: TimeInterval
    private var stateMachine = WiFiStateMachine()
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
        guard observersStore.isEnabled("wifi") else {
            collectorLogger.info("WiFiCollector disabled by master toggle")
            return
        }
        let intervalNs = UInt64(pollIntervalSec * 1_000_000_000)
        let interval = pollIntervalSec
        // Seed with current value (no emit on first observation).
        _ = stateMachine.observe(currentSnapshot())
        pollTask = Task { [weak self] in
            collectorLogger.info("WiFiCollector started (poll=\(interval, privacy: .public)s)")
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
        collectorLogger.info("WiFiCollector stopped")
    }

    private func tickOnce() async {
        let snapshot = currentSnapshot()
        guard let transition = stateMachine.observe(snapshot) else { return }
        let eventKind = "wifi_state_changed"
        let state: String
        switch transition {
        case .connected:    state = "connected"
        case .disconnected: state = "disconnected"
        }
        let raw = RawEvent(
            signalType: .context,
            bundleID: nil,
            payload: ["event_kind": eventKind, "state": state]
        )
        await writer.enqueue(raw)
        collectorLogger.info("WiFi transition -> \(state, privacy: .public)")
    }

    private func currentSnapshot() -> WiFiSnapshot {
        guard let interface = CWWiFiClient.shared().interface() else {
            return WiFiSnapshot(powerOn: false, mode: .none)
        }
        // Boundary reads ONLY .powerOn() + .interfaceMode().
        // **NEVER** reads .ssid() / .bssid() (Location TCC + PII).
        let powerOn = interface.powerOn()
        let mode = Self.mapMode(interface.interfaceMode())
        return WiFiSnapshot(powerOn: powerOn, mode: mode)
    }

    static func mapMode(_ raw: CWInterfaceMode) -> WiFiMode {
        switch raw {
        case .none:    return .none
        case .station: return .station
        case .IBSS:    return .ibss
        case .hostAP:  return .hostAP
        @unknown default: return .none
        }
    }
}
