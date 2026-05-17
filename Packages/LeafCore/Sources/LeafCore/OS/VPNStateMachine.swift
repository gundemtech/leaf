import Foundation

/// Phase Track-4 S3 — raw NEVPNStatus shape mirrored locally чтобы state
/// machine не зависел от NetworkExtension framework (Linux CI build). 6-way
/// enum 1:1 с `NEVPNStatus`: invalid/disconnected/connecting/connected/
/// reasserting/disconnecting.
public enum VPNRawStatus: Sendable, Hashable, CaseIterable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
}

/// Phase Track-4 S3 — pure transition detector для VPN. Collapses raw 6-way
/// status enum в 2-way stable state (connected | disconnected) и emits только
/// при реальной смене stable state. Intermediate states (.connecting,
/// .disconnecting, .reasserting) ignored — иначе flap'ило бы на каждом dial.
/// `.invalid` маппится в `.disconnected`.
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
            return nil  // intermediate — никаких state-обновлений
        }
        defer { lastStable = stable }
        guard let prior = lastStable else { return nil }
        return prior == stable ? nil : stable
    }
}
