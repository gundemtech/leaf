import Foundation

/// Phase Track-4 S2 — Apple Notes boundary value type. Only the active note's
/// title crosses. Body, plaintext, bodyHTML — explicitly absent so a regression
/// adding them is a public diff that must surface in review.
public struct NotesObservation: AdapterObservation, Hashable {
    public let activeNoteTitle: String?

    public init(activeNoteTitle: String?) {
        self.activeNoteTitle = activeNoteTitle
    }
}
