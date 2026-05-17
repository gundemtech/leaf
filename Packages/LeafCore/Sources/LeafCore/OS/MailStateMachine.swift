import Foundation

/// Phase Track-4 S2 — pure transition detector for Apple Mail. Emits
/// `mail_active_mailbox_changed` ONLY when:
///   1. the active mailbox name actually changed AND
///   2. the caller passes `mailboxNameOptedIn: true` (user enabled the
///      "Also capture mailbox names" sub-field toggle).
///
/// If the user opts out, the state machine still advances `prev` (so a later
/// opt-in doesn't replay stale transitions) but emits nothing.
public struct MailStateMachine: Sendable, Hashable {
    private var prev: MailObservation?

    public init() {}

    public mutating func observe(
        _ obs: MailObservation,
        nowMs: Int64,
        mailboxNameOptedIn: Bool
    ) -> [RawEvent] {
        defer { prev = obs }
        let changed: Bool = {
            guard let p = prev else { return true }
            return p.activeMailboxName != obs.activeMailboxName
        }()
        guard changed else { return [] }
        guard mailboxNameOptedIn else { return [] }
        var payload: [String: String] = ["event_kind": "mail_active_mailbox_changed"]
        if let name = obs.activeMailboxName { payload["mailbox_name"] = name }
        return [
            RawEvent(
                timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
                signalType: .attention,
                bundleID: "com.apple.mail",
                payload: payload
            )
        ]
    }
}
