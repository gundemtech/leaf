import Foundation

/// Phase Track-4 S2 — pure transition detector for Apple Notes. Emits
/// `notes_active_title_changed` when the active note title changes.
/// Boundary type carries only the title — note body never leaves the OS.
public struct NotesStateMachine: Sendable, Hashable {
    private var prev: NotesObservation?

    public init() {}

    public mutating func observe(_ obs: NotesObservation, nowMs: Int64) -> [RawEvent] {
        defer { prev = obs }
        let changed: Bool = {
            guard let p = prev else { return true }
            return p.activeNoteTitle != obs.activeNoteTitle
        }()
        guard changed else { return [] }
        var payload: [String: String] = ["event_kind": "notes_active_title_changed"]
        if let title = obs.activeNoteTitle { payload["note_title"] = title }
        return [RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
            signalType: .attention,
            bundleID: "com.apple.Notes",
            payload: payload
        )]
    }
}
