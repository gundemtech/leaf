import Foundation

/// Phase Track-4 S2 — return value of `AppleScriptBridge.executeScript`.
/// Sendable across actor boundaries. `descriptorData` carries the serialized
/// `NSAppleEventDescriptor` (NSObject-class, not directly Sendable) — adapters
/// deserialize via `NSKeyedUnarchiver` on receive.
public enum AppleScriptResult: Sendable, Equatable {
    case success(descriptorData: Data)
    case denied  // TCC denied (osa -1743)
    case appNotRunning  // target not running (-600)
    case timeout  // race or osa -1712
    case scriptError(code: Int, message: String)
    case unavailable  // catch-all (e.g. AS-blocking AV / MDM)
}
