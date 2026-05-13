import Foundation
import NetworkExtension
import os
import LeafCore

/// Phase Track-4 S3 — `NEVPNManager.shared()` status observer. Emits
/// `vpn_state_changed` на transition между stable states. Intermediate states
/// (.connecting / .disconnecting / .reasserting) ignored — иначе flap при
/// каждом dial.
///
/// **NEVER** reads serverAddress / passwordReference / любые credential fields
/// (ADR-010 Won't-list — VPN → state only).
///
/// **Limitation:** NEVPNManager.shared() observes только the first
/// system-configured VPN profile. Third-party VPNs that ship as Network
/// Extension (Cloudflare WARP, Tailscale, NordVPN tunnel-mode) не surface
/// here. Documented в OQ-S3-5.
@MainActor
final class VPNCollector {
    private let writer: EventWriter
    private let observersStore: SystemObserversStore
    private var stateMachine = VPNStateMachine()
    private var observer: NSObjectProtocol?

    init(writer: EventWriter, observersStore: SystemObserversStore) {
        self.writer = writer
        self.observersStore = observersStore
    }

    func start() async {
        guard observersStore.isEnabled("vpn") else {
            collectorLogger.info("VPNCollector disabled by master toggle")
            return
        }
        // Load preferences before observing — otherwise status returns .invalid.
        await loadPreferences()
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickOnce()
            }
        }
        // Seed with current value (no emit on first observation).
        tickOnce()
        collectorLogger.info("VPNCollector started")
    }

    func stop() async {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        collectorLogger.info("VPNCollector stopped")
    }

    private func loadPreferences() async {
        await withCheckedContinuation { cont in
            NEVPNManager.shared().loadFromPreferences { _ in
                cont.resume()
            }
        }
    }

    private func tickOnce() {
        let raw = Self.mapStatus(NEVPNManager.shared().connection.status)
        guard let transition = stateMachine.observe(raw) else { return }
        let eventKind = "vpn_state_changed"
        let state: String
        switch transition {
        case .connected:    state = "connected"
        case .disconnected: state = "disconnected"
        }
        let writer = self.writer
        Task {
            await writer.enqueue(RawEvent(
                signalType: .context,
                bundleID: nil,
                payload: ["event_kind": eventKind, "state": state]
            ))
        }
        collectorLogger.info("VPN transition -> \(state, privacy: .public)")
    }

    static func mapStatus(_ status: NEVPNStatus) -> VPNRawStatus {
        switch status {
        case .invalid:        return .invalid
        case .disconnected:   return .disconnected
        case .connecting:     return .connecting
        case .connected:      return .connected
        case .reasserting:    return .reasserting
        case .disconnecting:  return .disconnecting
        @unknown default:     return .invalid
        }
    }
}
