//
//  DebugDiagnosticsService.swift
//  fix/dev-launch-reliability
//
//  Main app сторона diagnostics: читает heartbeat файл написанный Agent'ом
//  + опционально открывает events.sqlite read-only для capture stats.
//  Surface — Settings → Diagnostics. Manual refresh (no polling) —
//  пользователь открывает редко, обновляется по тапу [Refresh].
//

import AppKit
import ApplicationServices
import Foundation
import LeafCore
import os
import SwiftUI

/// Снимок состояния процессов + DB на один момент времени.
struct DebugDiagnosticsSnapshot: Sendable, Equatable {
    // Main app process state
    let mainBundlePath: String
    let mainCDHash: String?
    let mainAXTrusted: Bool

    // Agent process state (from heartbeat, optional)
    let agentHeartbeat: DebugHeartbeat?
    let agentHeartbeatPath: URL

    // Capture state
    let dbURL: URL
    let dbExists: Bool
    let dbSizeBytes: Int64
    let walSizeBytes: Int64
    let totalEvents: Int?
    let lastEventAgeSec: TimeInterval?
    let eventsLastMinute: Int?
    let dbReadError: String?

    /// CDHash mismatch flag — main vs agent. red border в UI если true.
    var cdHashMismatch: Bool {
        guard let main = mainCDHash, let agent = agentHeartbeat?.cdHash else { return false }
        return main != agent
    }
}

@MainActor
@Observable
final class DebugDiagnosticsService {
    private(set) var snapshot: DebugDiagnosticsSnapshot
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "diagnostics")

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = InsightsReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = InsightsReader.defaultEncryption()
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.snapshot = Self.makeEmptySnapshot(at: databaseURL)
        // Не auto-refresh при init — пользователь сам нажимает [Refresh]
        // когда открывает секцию. Init дешёвый (UI рендерится сразу).
    }

    /// Manual refresh — собирает свежий snapshot.
    func refresh() {
        let mainPath = DebugDiagnostics.currentProcessBundlePath()
        let mainHash = DebugDiagnostics.currentProcessCDHash()
        let axTrusted = AXIsProcessTrusted()
        let heartbeat = DebugHeartbeat.read()
        let heartbeatURL = DebugHeartbeat.defaultURL()

        let dbExists = FileManager.default.fileExists(atPath: databaseURL.path)
        let dbSize = DebugDiagnostics.dbFileSize(at: databaseURL)
        let walSize = DebugDiagnostics.dbWalSize(at: databaseURL)

        var totalEvents: Int? = nil
        var lastEventAge: TimeInterval? = nil
        var eventsLastMin: Int? = nil
        var dbReadError: String? = nil

        if dbExists {
            do {
                let db = try LeafCore.Database.openForRead(
                    at: databaseURL,
                    config: databaseConfig,
                    encryption: databaseEncryption
                )
                totalEvents = try DebugDiagnostics.totalEvents(database: db)
                if let lastMs = try DebugDiagnostics.lastEventAtMs(database: db) {
                    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                    lastEventAge = TimeInterval(nowMs - lastMs) / 1000.0
                }
                eventsLastMin = try DebugDiagnostics.eventsInLastMinute(database: db)
            } catch {
                dbReadError = error.localizedDescription
                logger.warning(
                    "DB read failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        snapshot = DebugDiagnosticsSnapshot(
            mainBundlePath: mainPath,
            mainCDHash: mainHash,
            mainAXTrusted: axTrusted,
            agentHeartbeat: heartbeat,
            agentHeartbeatPath: heartbeatURL,
            dbURL: databaseURL,
            dbExists: dbExists,
            dbSizeBytes: dbSize,
            walSizeBytes: walSize,
            totalEvents: totalEvents,
            lastEventAgeSec: lastEventAge,
            eventsLastMinute: eventsLastMin,
            dbReadError: dbReadError
        )
    }

    /// Reveal a path в Finder (если файл существует).
    func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Show parent directory if the file itself is gone.
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
            }
        }
    }

    /// Сборка plain-text дампа для bug-репорта в clipboard.
    func copyToClipboard() {
        let s = snapshot
        var lines: [String] = []
        lines.append("LEAF DIAGNOSTICS — \(Self.timestamp())")
        lines.append("")
        lines.append("# Main app")
        lines.append("  bundle path : \(s.mainBundlePath)")
        lines.append("  CDHash      : \(s.mainCDHash ?? "—")")
        lines.append("  AX trusted  : \(s.mainAXTrusted ? "yes" : "no")")
        lines.append("")
        lines.append("# Agent")
        if let h = s.agentHeartbeat {
            lines.append("  PID         : \(h.pid)")
            lines.append("  bundle path : \(h.bundlePath)")
            lines.append("  CDHash      : \(h.cdHash ?? "—")")
            lines.append("  AX trusted  : \(h.axTrusted ? "yes" : "no")")
            lines.append("  heartbeat   : \(Int(h.ageSec))s ago\(h.isStale() ? " (STALE)" : "")")
        } else {
            lines.append("  (no heartbeat file at \(s.agentHeartbeatPath.path))")
        }
        if s.cdHashMismatch {
            lines.append("  ⚠ CDHash mismatch — main и agent подписаны разными identity")
        }
        lines.append("")
        lines.append("# Capture")
        lines.append("  db url      : \(s.dbURL.path)")
        lines.append("  db exists   : \(s.dbExists ? "yes" : "no")")
        lines.append("  db size     : \(Self.formatBytes(s.dbSizeBytes))")
        lines.append("  wal size    : \(Self.formatBytes(s.walSizeBytes))")
        if let n = s.totalEvents {
            lines.append("  events total: \(n)")
        }
        if let age = s.lastEventAgeSec {
            lines.append("  last event  : \(Self.formatAge(age))")
        }
        if let n = s.eventsLastMinute {
            lines.append("  events/min  : \(n)")
        }
        if let err = s.dbReadError {
            lines.append("  db error    : \(err)")
        }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Открыть Console.app с предзаполненной search query (best-effort).
    /// Console.app не имеет publicly documented x-callback URL для search,
    /// поэтому просто открываем приложение — юзер сам введёт subsystem.
    func openConsoleApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    private static func makeEmptySnapshot(at url: URL) -> DebugDiagnosticsSnapshot {
        DebugDiagnosticsSnapshot(
            mainBundlePath: DebugDiagnostics.currentProcessBundlePath(),
            mainCDHash: nil,
            mainAXTrusted: false,
            agentHeartbeat: nil,
            agentHeartbeatPath: DebugHeartbeat.defaultURL(),
            dbURL: url,
            dbExists: false,
            dbSizeBytes: 0,
            walSizeBytes: 0,
            totalEvents: nil,
            lastEventAgeSec: nil,
            eventsLastMinute: nil,
            dbReadError: nil
        )
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f.string(from: Date())
    }

    static func formatBytes(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1_048_576 { return String(format: "%.1f KB", Double(n) / 1024.0) }
        return String(format: "%.1f MB", Double(n) / 1_048_576.0)
    }

    static func formatAge(_ sec: TimeInterval) -> String {
        let s = Int(sec)
        if s < 60 { return "\(s)s ago" }
        if s < 3_600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3_600)h ago" }
        return "\(s / 86_400)d ago"
    }

    static func formatHashShort(_ hash: String?) -> String {
        guard let hash, !hash.isEmpty else { return "—" }
        if hash.count <= 16 { return hash }
        return String(hash.prefix(16)) + "…"
    }
}
