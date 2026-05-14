import Foundation

/// Phase Track-5 S4 — direct-message template type. Three values fixed in
/// contract §8.1 (handoff / task / ping). Wire-serialized as raw lowercase
/// strings in both Supabase `direct_messages.kind` and local SQLCipher
/// `messages_mirror.kind`.
public enum DirectMessageKind: String, Sendable, Codable, CaseIterable, Hashable {
    case handoff
    case task
    case ping
}
