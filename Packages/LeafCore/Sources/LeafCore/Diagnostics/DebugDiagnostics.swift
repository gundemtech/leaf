import Foundation
import GRDB
import Security

/// Diagnostic helpers для понимания «почему опять не детектит» без поиска.
/// Surface (Settings → Diagnostics) показывает:
///   - main app CDHash + bundle path + AX trust state
///   - Agent CDHash + bundle path + AX trust state (через heartbeat file)
///   - events.sqlite size + total events + last event age + events/min
///
/// Не gated `#if DEBUG` — alpha build шипится с теми же гарантиями,
/// и юзеру нужна та же видимость в проде.
public enum DebugDiagnostics {

    // MARK: - Code signing identity

    /// CDHash текущего процесса. Hex-encoded, 40 chars (SHA-1) или 64 chars
    /// (SHA-256) в зависимости от signing identity. Возвращает nil если
    /// process unsigned (rare на macOS, но допустимо в headless CI).
    public static func currentProcessCDHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return cdHash(from: code)
    }

    /// CDHash живого процесса по PID. Возвращает nil если PID не существует
    /// либо если процесс ad-hoc-signed (CDHash присутствует, но без identity
    /// reference). Использует `SecCodeCopyGuestWithAttributes` поверх hostess
    /// kernel — стандартный path для cross-process inspect.
    public static func cdHash(forPID pid: pid_t) -> String? {
        var host: SecCode?
        guard SecCodeCopySelf([], &host) == errSecSuccess, let host else { return nil }
        let attrs: NSDictionary = [kSecGuestAttributePid as String: pid]
        var guest: SecCode?
        let status = SecCodeCopyGuestWithAttributes(host, attrs, [], &guest)
        guard status == errSecSuccess, let guest else { return nil }
        return cdHash(from: guest)
    }

    /// Bundle path текущего процесса — куда LaunchServices фактически resolve'нул
    /// executable. Полезно для проверки «работаю ли я из DerivedData или из
    /// /Applications hijack».
    public static func currentProcessBundlePath() -> String {
        Bundle.main.bundleURL.path
    }

    // MARK: - launchd / BTM state

    /// Состояние Agent labels в user-domain launchd. Возвращается parse'ом
    /// `launchctl list` (public API, без sudo). Когда BTM parent disposition
    /// = disabled (recurring Sequoia bug после sleep/wake/rebuild), agent
    /// label loaded в launchd но не запущен → `loaded=true, runningPID=nil`.
    /// Это сигнал для UI показать «Open Login Items» banner.
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

    /// Размер events.sqlite в байтах. Возвращает 0 если файл отсутствует.
    /// WAL + SHM tracked отдельно — caller суммирует если хочет total disk.
    public static func dbFileSize(at url: URL = DatabasePath.defaultURL()) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Размер `-wal` sidecar. Если ненулевой — Agent активно пишет, просто
    /// checkpoint ещё не сработал. Это нормально, не bug.
    public static func dbWalSize(at url: URL = DatabasePath.defaultURL()) -> Int64 {
        let wal = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + "-wal")
        let attrs = try? FileManager.default.attributesOfItem(atPath: wal.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Timestamp (ms epoch) самого свежего события в `events` таблице.
    /// Возвращает nil если таблица пустая.
    public static func lastEventAtMs(database: Database) throws -> Int64? {
        try database.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(\(Schema.Events.ts)) FROM \(Schema.Events.tableName)")
        }
    }

    /// Кол-во events записанных за последнюю минуту относительно `now`.
    /// Используется для «healthy capture»-индикатора (≥1 = pipeline жив).
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

/// Cross-process status pipe. Agent раз в N секунд пишет heartbeat файл с
/// текущим PID, AX trust state, CDHash, и timestamp. Main app читает чтобы
/// показать в Diagnostics секции (без XPC, без socket connection).
///
/// Если файл older `staleThresholdSec` — Agent считается unresponsive
/// (либо crashed, либо launchd не respawn'ит).
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

    /// Канонический путь heartbeat файла. Тот же каталог что и events.sqlite —
    /// permissions/ownership уже user-owned.
    public static func defaultURL() -> URL {
        DatabasePath.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("agent-heartbeat.json", isDirectory: false)
    }

    /// Atomic write через temp + rename. Не throw — caller обрабатывает
    /// graceful (Agent логирует один раз и продолжает работу).
    public func write(to url: URL = DebugHeartbeat.defaultURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        let tmp = url.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: tmp, options: [.atomic])
        // FileManager.replaceItem honors atomic semantics if same volume.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Чтение последнего heartbeat. nil если файл отсутствует / corrupted.
    public static func read(from url: URL = DebugHeartbeat.defaultURL()) -> DebugHeartbeat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DebugHeartbeat.self, from: data)
    }

    /// Возраст heartbeat относительно `now` в секундах. nil если нет heartbeat.
    public var ageSec: TimeInterval {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return TimeInterval(nowMs - tsMs) / 1000.0
    }

    /// Heartbeat считается stale (Agent unresponsive) если age > threshold.
    /// Default 120s — Agent пишет каждые 30s, threshold 4× даёт запас на
    /// system sleep / heavy I/O.
    public func isStale(staleThresholdSec: TimeInterval = 120) -> Bool {
        ageSec > staleThresholdSec
    }
}
