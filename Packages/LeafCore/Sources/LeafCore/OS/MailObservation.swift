import Foundation

/// Phase Track-4 S2 — Apple Mail boundary value type. Carries only the
/// currently-selected mailbox name; emission is further gated by the user's
/// per-app "Also capture mailbox names" sub-field opt-in. Body / content /
/// subject / sender / recipient / from / to never cross.
public struct MailObservation: AdapterObservation, Hashable {
    public let activeMailboxName: String?

    public init(activeMailboxName: String?) {
        self.activeMailboxName = activeMailboxName
    }
}
