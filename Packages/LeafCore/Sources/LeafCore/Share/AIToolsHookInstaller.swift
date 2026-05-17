import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Track-6 P1 — install/uninstall Leaf hooks block in `~/.claude/settings.json`.
/// Idempotent; preserves user's foreign hook entries. POSIX flock for write
/// serialization (Claude CLI may concurrent-write); atomic temp+rename to
/// avoid torn writes.
///
/// Install algorithm:
///   1. Acquire flock on settings.json (1s timeout, retry once)
///   2. Read + parse JSON (create empty {} if file missing)
///   3. Remove existing Leaf entries (filter by bridgePath prefix OR substring
///      "leaf-hook-bridge" — catches drift case where Leaf.app moved)
///   4. Append 5 Leaf entries (PreToolUse/PostToolUse/UserPromptSubmit/SessionEnd/PreCompact)
///   5. Pretty-print JSON, write to temp, atomic rename
///   6. Release flock
public final class AIToolsHookInstaller: @unchecked Sendable {
    public enum InstallResult: Equatable, Sendable {
        case ok
        case partial(String)
        case failed(String)
    }

    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        case drifted  // Leaf entries present but bundle path differs from current
    }

    private let settingsURL: URL
    private let bundlePath: String
    private let bridgeRelativePath: String

    /// `settingsURL` defaults to `~/.claude/settings.json`; override for tests.
    /// `bundlePath` defaults to `Bundle.main.bundlePath` (Leaf.app location);
    /// `bridgeRelativePath` defaults to `Contents/MacOS/leaf-hook-bridge`.
    public init(
        settingsURL: URL = URL(fileURLWithPath: ("~/.claude/settings.json" as NSString).expandingTildeInPath),
        bundlePath: String = Bundle.main.bundlePath,
        bridgeRelativePath: String = "Contents/MacOS/leaf-hook-bridge"
    ) {
        self.settingsURL = settingsURL
        self.bundlePath = bundlePath
        self.bridgeRelativePath = bridgeRelativePath
    }

    public var bridgeCommandPath: String {
        "\(bundlePath)/\(bridgeRelativePath)"
    }

    public func install() throws -> InstallResult {
        try acquireLockAndMutate { json in
            removeLeafEntries(from: &json)
            addLeafEntries(to: &json)
        }
        return .ok
    }

    public func uninstall() throws -> InstallResult {
        try acquireLockAndMutate { json in
            removeLeafEntries(from: &json)
        }
        return .ok
    }

    public func currentStatus() -> Status {
        guard let data = try? Data(contentsOf: settingsURL),
            !data.isEmpty,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = json["hooks"] as? [String: Any]
        else {
            return .notInstalled
        }
        let bridgePath = bridgeCommandPath
        var hasMatching = false
        var hasMismatching = false
        for (_, value) in hooks {
            guard let arr = value as? [[String: Any]] else { continue }
            for matcher in arr {
                let innerHooks = matcher["hooks"] as? [[String: Any]] ?? []
                for inner in innerHooks {
                    let cmd = (inner["command"] as? String) ?? ""
                    if cmd.hasPrefix(bridgePath) {
                        hasMatching = true
                    } else if cmd.contains("/leaf-hook-bridge ") || cmd.hasSuffix("/leaf-hook-bridge") {
                        hasMismatching = true
                    }
                }
            }
        }
        if hasMatching { return .installed }
        if hasMismatching { return .drifted }
        return .notInstalled
    }

    // MARK: - Private

    private func acquireLockAndMutate(_ mutator: (inout [String: Any]) -> Void) throws {
        // Ensure parent dir exists (idempotent — withIntermediateDirectories: true).
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let path = settingsURL.path
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw NSError(
                domain: "AIToolsHookInstaller", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "open failed errno=\(errno)"])
        }
        defer { close(fd) }

        // Non-blocking flock with 1s retry budget.
        var lockOK = flock(fd, LOCK_EX | LOCK_NB) == 0
        if !lockOK {
            usleep(500_000)
            lockOK = flock(fd, LOCK_EX | LOCK_NB) == 0
        }
        guard lockOK else {
            throw NSError(
                domain: "AIToolsHookInstaller", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "settings.json locked by another process"])
        }
        defer { _ = flock(fd, LOCK_UN) }

        // Read current contents.
        let existing = (try? Data(contentsOf: settingsURL)) ?? Data()
        var json: [String: Any]
        if existing.isEmpty {
            json = [:]
        } else if let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            json = parsed
        } else {
            // Malformed JSON — recover by writing fresh {}. We do NOT silently
            // overwrite a non-empty file the user may have hand-edited badly;
            // throw so the UI can show error and let the user fix it.
            throw NSError(
                domain: "AIToolsHookInstaller", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "settings.json contains invalid JSON"])
        }

        mutator(&json)

        // Atomic write: temp file in same dir + rename.
        let tempURL =
            settingsURL
            .deletingLastPathComponent()
            .appendingPathComponent("settings.json.tmp-\(UUID().uuidString)")
        let outData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        do {
            try outData.write(to: tempURL, options: [.atomic])
            // Replace the original with the temp file atomically.
            _ = try FileManager.default.replaceItemAt(settingsURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private func removeLeafEntries(from json: inout [String: Any]) {
        guard var hooks = json["hooks"] as? [String: Any] else {
            return
        }
        let bridgePath = bridgeCommandPath
        for (eventName, value) in hooks {
            guard var arr = value as? [[String: Any]] else { continue }
            arr.removeAll { matcher in
                let innerHooks = matcher["hooks"] as? [[String: Any]] ?? []
                // A matcher block is "Leaf-owned" iff ALL its inner hooks are Leaf entries.
                // (This avoids dropping a user matcher block that mixes Leaf + foreign hooks.
                //  Edge case: user shouldn't be doing that, but defend against it.)
                guard !innerHooks.isEmpty else { return false }
                return innerHooks.allSatisfy { inner in
                    let cmd = (inner["command"] as? String) ?? ""
                    return cmd.hasPrefix(bridgePath)
                        || cmd.contains("/leaf-hook-bridge ")
                        || cmd.hasSuffix("/leaf-hook-bridge")
                }
            }
            if arr.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = arr
            }
        }
        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }
    }

    private func addLeafEntries(to json: inout [String: Any]) {
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let plan: [(event: String, matcher: String)] = [
            ("PreToolUse", "*"),
            ("PostToolUse", "*"),
            ("UserPromptSubmit", "*"),
            ("SessionEnd", "*"),
            ("PreCompact", "manual|auto"),
        ]
        for (event, matcher) in plan {
            var arr = hooks[event] as? [[String: Any]] ?? []
            arr.append([
                "matcher": matcher,
                "hooks": [
                    [
                        "type": "command",
                        "command": "\(bridgeCommandPath) \(event)",
                        "timeout": 2,
                    ]
                ],
            ])
            hooks[event] = arr
        }
        json["hooks"] = hooks
    }
}
