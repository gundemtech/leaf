import Foundation
import GRDB
import Security

/// Diagnostic helpers for figuring out "why isn't it detecting again" without digging.
/// The surface (Settings → Diagnostics) shows:
///   - main app CDHash + bundle path + AX trust state
///   - Agent CDHash + bundle path + AX trust state (via heartbeat file)
///   - events.sqlite size + total events + last event age + events/min
///
/// Not gated by `#if DEBUG` — the alpha build ships with the same guarantees,
/// and the user needs the same visibility in production.
public enum DebugDiagnostics {

    // MARK: - Code signing identity

    /// CDHash of the current process. Hex-encoded, 40 chars (SHA-1) or 64 chars
    /// (SHA-256) depending on the signing identity. Returns nil if the
    /// process is unsigned (rare on macOS, but acceptable in headless CI).
    public static func currentProcessCDHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return cdHash(from: code)
    }

    /// CDHash of a live process by PID. Returns nil if the PID doesn't exist
    /// or if the process is ad-hoc-signed (CDHash present, but without an identity
    /// reference). Uses `SecCodeCopyGuestWithAttributes` over the hostess
    /// kernel — the standard path for cross-process inspection.
    public static func cdHash(forPID pid: pid_t) -> String? {
        var host: SecCode?
        guard SecCodeCopySelf([], &host) == errSecSuccess, let host else { return nil }
        let attrs: NSDictionary = [kSecGuestAttributePid as String: pid]
        var guest: SecCode?
        let status = SecCodeCopyGuestWithAttributes(host, attrs, [], &guest)
        guard status == errSecSuccess, let guest else { return nil }
        return cdHash(from: guest)
    }

    /// Bundle path of the current process — where LaunchServices actually resolved
    /// the executable. Useful for checking "am I running from DerivedData or from
    /// an /Applications hijack".
    public static func currentProcessBundlePath() -> String {
        Bundle.main.bundleURL.path
    }

    // MARK: - launchd / BTM state

    /// State of the Agent labels in user-domain launchd. Obtained by parsing
    /// `launchctl list` (public API, no sudo). When the BTM parent disposition
    /// = disabled (recurring Sequoia bug after sleep/wake/rebuild), the agent
    /// label is loaded in launchd but not running → `loaded=true, runningPID=nil`.
    /// That's the signal for the UI to show the "Open Login Items" banner.
    public struct AgentLaunchdState: Sendable, Equatable {
        public let loaded: Bool
        public let runningPID: pid_t?

        public init(loaded: Bool, runningPID: pid_t?) {
            self.loaded = loaded
            self.runningPID = runningPID
        }
    }

    public static func agentLaunchdState(label: String = "tech.gundem.leaf.agent") -> AgentLaunchdState {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return AgentLaunchdState(loaded: false, runningPID: nil)
        }
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
            let output = String(data: data, encoding: .utf8)
        else {
            return AgentLaunchdState(loaded: false, runningPID: nil)
        }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let lineLabel = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard lineLabel == label else { continue }
            let pidField = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let pid = pid_t(pidField)
            return AgentLaunchdState(loaded: true, runningPID: pid)
        }
        return AgentLaunchdState(loaded: false, runningPID: nil)
    }

    private static func cdHash(from code: SecCode) -> String? {
        let flags = SecCSFlags(rawValue: 0)
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, flags, &staticCode) == errSecSuccess,
            let staticCode
        else { return nil }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
            let info = infoRef as? [String: Any],
            let data = info[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Event capture stats

    /// Size of events.sqlite in bytes. Returns 0 if the file is absent.
    /// WAL + SHM are tracked separately — the caller sums them if it wants total disk.
    public static func dbFileSize(at url: URL = DatabasePath.defaultURL()) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Size of the `-wal` sidecar. If non-zero — the Agent is actively writing,
    /// the checkpoint just hasn't fired yet. This is normal, not a bug.
    public static func dbWalSize(at url: URL = DatabasePath.defaultURL()) -> Int64 {
        let wal = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + "-wal")
        let attrs = try? FileManager.default.attributesOfItem(atPath: wal.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Timestamp (ms epoch) of the most recent event in the `events` table.
    /// Returns nil if the table is empty.
    public static func lastEventAtMs(database: Database) throws -> Int64? {
        try database.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(\(Schema.Events.ts)) FROM \(Schema.Events.tableName)")
        }
    }

    /// Number of events written in the last minute relative to `now`.
    /// Used for the "healthy capture" indicator (≥1 = pipeline alive).
    public static func eventsInLastMinute(database: Database, now: Date = Date()) throws -> Int {
        let cutoffMs = Int64(now.timeIntervalSince1970 * 1000) - 60_000
        return try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(Schema.Events.tableName) WHERE \(Schema.Events.ts) >= ?",
                arguments: [cutoffMs]
            ) ?? 0
        }
    }

    /// Total events count.
    public static func totalEvents(database: Database) throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(Schema.Events.tableName)") ?? 0
        }
    }
}

// MARK: - Agent heartbeat

/// Cross-process status pipe. Every N seconds the Agent writes a heartbeat file
/// with the current PID, AX trust state, CDHash, and timestamp. The main app reads it
/// to display in the Diagnostics section (no XPC, no socket connection).
///
/// If the file is older than `staleThresholdSec` — the Agent is considered unresponsive
/// (either crashed, or launchd isn't respawning it).
public struct DebugHeartbeat: Codable, Sendable, Hashable {
    public let pid: Int32
    public let axTrusted: Bool
    public let cdHash: String?
    public let bundlePath: String
    public let tsMs: Int64

    public init(pid: Int32, axTrusted: Bool, cdHash: String?, bundlePath: String, tsMs: Int64) {
        self.pid = pid
        self.axTrusted = axTrusted
        self.cdHash = cdHash
        self.bundlePath = bundlePath
        self.tsMs = tsMs
    }

    /// Canonical path of the heartbeat file. Same directory as events.sqlite —
    /// permissions/ownership are already user-owned.
    public static func defaultURL() -> URL {
        DatabasePath.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("agent-heartbeat.json", isDirectory: false)
    }

    /// Atomic write via temp + rename. Does not throw — the caller handles it
    /// gracefully (the Agent logs once and keeps running).
    public func write(to url: URL = DebugHeartbeat.defaultURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        let tmp = url.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: tmp, options: [.atomic])
        // FileManager.replaceItem honors atomic semantics if same volume.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Read the latest heartbeat. nil if the file is absent / corrupted.
    public static func read(from url: URL = DebugHeartbeat.defaultURL()) -> DebugHeartbeat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DebugHeartbeat.self, from: data)
    }

    /// Age of the heartbeat relative to `now` in seconds. nil if there is no heartbeat.
    public var ageSec: TimeInterval {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return TimeInterval(nowMs - tsMs) / 1000.0
    }

    /// The heartbeat is considered stale (Agent unresponsive) if age > threshold.
    /// Default 120s — the Agent writes every 30s, a 4× threshold leaves headroom for
    /// system sleep / heavy I/O.
    public func isStale(staleThresholdSec: TimeInterval = 120) -> Bool {
        ageSec > staleThresholdSec
    }
}
