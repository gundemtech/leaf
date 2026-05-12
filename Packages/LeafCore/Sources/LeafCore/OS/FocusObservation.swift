import Foundation

/// Phase Track-4 S1 — OS-boundary value type carrying ONLY whether the user is
/// currently in Focus mode. Translated from `INFocusStatusCenter` at the
/// FocusModeCollector boundary in LeafAgent. macOS public API does not expose
/// the mode name (`INFocusStatus.isFocused: Bool?` only) — even if it did, by
/// architectural choice we capture boolean only.
public struct FocusObservation: Sendable, Hashable {
    public let isFocused: Bool

    public init(isFocused: Bool) {
        self.isFocused = isFocused
    }
}
