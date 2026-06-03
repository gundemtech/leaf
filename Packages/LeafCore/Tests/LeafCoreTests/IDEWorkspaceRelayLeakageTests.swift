// Settings dead-toggle remediation (WS1) — privacy regression for the now-live
// IDE workspace watchers. `vscode_workspace_opened` /
// `jetbrains_recent_project_observed` carry a tilde-prefixed `workspace_root`
// path. They are LOCAL-only (ShareSourceClassifier has no IDE source → unmapped
// → never team-broadcast), so the path must never reach any
// `presence_state.state_json` (the relay-broadcast surface). Mirrors the
// Track-3 D1/D2 seed-then-write sentinel pattern in RelayBodyLeakageTests.

import GRDB
import XCTest

@testable import LeafCore

final class IDEWorkspaceRelayLeakageTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-ws1-ide-leak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testIDEWorkspaceRootDoesNotLeakIntoPresenceState() throws {
        let db = try Database.openForWrite(
            at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Seed a presence_state row so the negative assertion is non-vacuous.
        try db.writeEventsOffsetAndPresence(
            [],
            offset: CollectorOffset(
                collectorID: CollectorID.linearPolling, sourceID: "linear:test",
                byteOffset: 0, inode: nil, size: 0, lastModifiedMs: nowMs, updatedMs: nowMs),
            presence: (provider: .linear, state: [:] as [String: Any], derivedMode: nil),
            nowMs: nowMs
        )

        let vscode = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .attention,
            bundleID: "com.microsoft.VSCode",
            payload: [
                "event_kind": "vscode_workspace_opened",
                "workspace_name": "leaf",
                "workspace_root": "~/Desktop/Leaf/VSCODE-ROOT-SENTINEL",
                "outside_watched_folder": "true",
            ])
        let jetbrains = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            signalType: .attention,
            bundleID: "com.jetbrains.intellij",
            payload: [
                "event_kind": "jetbrains_recent_project_observed",
                "ide_version_dir": "IntelliJIdea2025.1",
                "project_name": "leaf",
                "workspace_root": "~/Desktop/Leaf/JETBRAINS-ROOT-SENTINEL",
                "outside_watched_folder": "true",
            ])
        // Same write path the agent's IDE eventSink uses (direct DB batch write).
        try db.write([vscode, jetbrains])

        try db.readSQL { rawDB in
            let rows = try Row.fetchAll(rawDB, sql: "SELECT state_json FROM presence_state")
            XCTAssertFalse(rows.isEmpty, "presence_state row should exist after seed")
            for row in rows {
                let stateJSON = (row["state_json"] as String?) ?? ""
                XCTAssertFalse(
                    stateJSON.contains("VSCODE-ROOT-SENTINEL"),
                    "VSCode workspace_root MUST NOT leak into presence_state.state_json")
                XCTAssertFalse(
                    stateJSON.contains("JETBRAINS-ROOT-SENTINEL"),
                    "JetBrains workspace_root MUST NOT leak into presence_state.state_json")
            }
        }
    }
}
