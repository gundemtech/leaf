import Foundation

/// Phase Track-4 S3 — raw NEVPNStatus shape mirrored locally so the state
/// machine doesn't depend on the NetworkExtension framework (Linux CI build). 6-way
/// enum 1:1 with `NEVPNStatus`: invalid/disconnected/connecting/connected/
/// reasserting/disconnecting.
public enum VPNRawStatus: Sendable, Hashable, CaseIterable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
}

/// Phase Track-4 S3 — pure transition detector for VPN. Collapses the raw 6-way
/// status enum into a 2-way stable state (connected | disconnected) and emits only
/// on an actual change of stable state. Intermediate states (.connecting,
/// .disconnecting, .reasserting) ignored — otherwise it would flap on every dial.
/// `.invalid` maps to `.disconnected`.
public struct VPNStateMachine: Sendable, Hashable {
    public enum StableState: Sendable, Hashable { case connected, disconnected }

    private var lastStable: StableState?

    public init() {}

    /// Returns destination StableState iff (a) raw status maps to a stable
    /// value AND (b) it differs from prior stable state.
    public mutating func observe(_ raw: VPNRawStatus) -> StableState? {
        let stable: StableState
        switch raw {
        case .connected: stable = .connected
        case .disconnected, .invalid: stable = .disconnected
        case .connecting, .disconnecting, .reasserting:
            return nil   // intermediate — no state updates
        }
        defer { lastStable = stable }
        guard let prior = lastStable else { return nil }
        return prior == stable ? nil : stable
    }
}
