import Foundation

public enum LeafError: Error, Sendable {
    case notImplemented
    case databaseUnavailable
    case keychainUnavailable(OSStatus)
    case keyFileUnavailable(reason: String)
    case keyFileCorrupted
    case corruptedEnvelope
    case invalidPayload
}
