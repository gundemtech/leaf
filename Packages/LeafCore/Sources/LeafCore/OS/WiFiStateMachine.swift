import Foundation

/// Phase Track-4 S3 — `CWInterface.interfaceMode` mirror enum. Independent of
/// the CoreWLAN import so the state machine is testable without a framework dependency.
/// 4-way 1:1 with `CWInterfaceMode`.
public enum WiFiMode: Sendable, Hashable, CaseIterable {
    case none      // CWInterfaceMode.none = 0
    case station   // CWInterfaceMode.station = 1 (client connected to AP)
    case ibss      // CWInterfaceMode.IBSS = 2 (ad-hoc)
    case hostAP    // CWInterfaceMode.hostAP = 3
}

/// Phase Track-4 S3 — snapshot input for WiFiStateMachine from
/// `WiFiCollector.tickOnce()`.
public struct WiFiSnapshot: Sendable, Hashable {
    public let powerOn: Bool
    public let mode: WiFiMode

    public init(powerOn: Bool, mode: WiFiMode) {
        self.powerOn = powerOn
        self.mode = mode
    }
}

/// Phase Track-4 S3 — pure transition detector. Derives a 2-way stable state
/// (connected | disconnected) from the (powerOn, mode) pair:
///   connected ⟺ powerOn && mode == .station
/// otherwise disconnected. Emits only on an actual change of stable state.
/// First-observation primes state without emitting.
///
/// **SSID is never materialized** (ADR-010 Won't-list — wifi → state only).
public struct WiFiStateMachine: Sendable, Hashable {
    public enum StableState: Sendable, Hashable { case connected, disconnected }

    private var lastStable: StableState?

    public init() {}

    public mutating func observe(_ snapshot: WiFiSnapshot) -> StableState? {
        let stable: StableState =
            (snapshot.powerOn && snapshot.mode == .station) ? .connected : .disconnected
        defer { lastStable = stable }
        guard let prior = lastStable else { return nil }
        return prior == stable ? nil : stable
    }
}
