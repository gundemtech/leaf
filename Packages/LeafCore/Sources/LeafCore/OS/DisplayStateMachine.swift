import Foundation

/// Phase Track-4 S3 — input для DisplayStateMachine. Constructed by
/// `DisplayCollector` от `CGDisplayChangeSummaryFlags`-фильтра.
public struct DisplayChange: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case connected, disconnected }

    public let displayId: UInt32
    public let kind: Kind

    public init(displayId: UInt32, kind: Kind) {
        self.displayId = displayId
        self.kind = kind
    }
}

public enum DisplayTransition: Sendable, Hashable {
    case connected(UInt32)
    case disconnected(UInt32)
}

/// Phase Track-4 S3 — tracked-set state machine для display add/remove events.
/// Suppresses duplicate-add (we already think this display is connected) и
/// remove-of-unknown (we never saw this display added — e.g. agent missed
/// the connection event). CGDisplayRegisterReconfigurationCallback fires only
/// on CHANGE, not boot state; agent emits только реальные transitions.
public struct DisplayStateMachine: Sendable {
    private var connected: Set<UInt32> = []

    public init() {}

    public mutating func observe(_ change: DisplayChange) -> DisplayTransition? {
        switch change.kind {
        case .connected:
            if connected.contains(change.displayId) { return nil }
            connected.insert(change.displayId)
            return .connected(change.displayId)
        case .disconnected:
            if !connected.contains(change.displayId) { return nil }
            connected.remove(change.displayId)
            return .disconnected(change.displayId)
        }
    }
}
