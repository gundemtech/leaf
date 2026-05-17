import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Phase Track-4 S2 — @MainActor wrapper around NSAppleScript.
/// Bridges main-thread-bound AS execution into the async/await world with:
///  - injectable executor closure (tests pass a mock; production wraps NSAppleScript)
///  - timeout race (first of executor vs `Task.sleep`)
///  - error-code mapping (-1743 → denied, -600 → appNotRunning, -1712 → timeout)
@MainActor
public final class AppleScriptBridge {
    public typealias Executor = @Sendable (String) async throws -> AppleScriptResult

    private let executor: Executor

    public init(executor: @escaping Executor) {
        self.executor = executor
    }

    public func executeScript(_ script: String, timeoutSec: Double) async -> AppleScriptResult {
        await withTaskGroup(of: AppleScriptResult.self) { group in
            group.addTask { [executor] in
                (try? await executor(script)) ?? .unavailable
            }
            group.addTask {
                let nanos = UInt64(max(0, timeoutSec) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return .timeout
            }
            let first = await group.next() ?? .unavailable
            group.cancelAll()
            return first
        }
    }

    #if canImport(AppKit)
    /// Production factory — runs `NSAppleScript` on the main actor. Error
    /// dictionary parsed for canonical AppleEvent codes.
    public static func production() -> AppleScriptBridge {
        AppleScriptBridge(executor: { script in
            await MainActor.run {
                Self.runNSAppleScript(script)
            }
        })
    }

    static func runNSAppleScript(_ script: String) -> AppleScriptResult {
        guard let asObj = NSAppleScript(source: script) else {
            return .scriptError(code: -2741, message: "init failed")
        }
        var errorDict: NSDictionary?
        let descriptor = asObj.executeAndReturnError(&errorDict)
        if let err = errorDict as? [String: Any] {
            let code = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
            let message = (err["NSAppleScriptErrorMessage"] as? String) ?? "unknown"
            switch code {
            case -1743: return .denied
            case -600: return .appNotRunning
            case -1712: return .timeout
            default: return .scriptError(code: code, message: message)
            }
        }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: descriptor, requiringSecureCoding: true) {
            return .success(descriptorData: data)
        }
        return .success(descriptorData: Data())
    }
    #endif
}
