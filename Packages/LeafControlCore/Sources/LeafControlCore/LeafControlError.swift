import Foundation

public enum LeafControlError: Error, Sendable {
    case notImplemented
    case databaseUnavailable
    case keychainUnavailable(OSStatus)
    case corruptedEnvelope
    case invalidPayload
}
