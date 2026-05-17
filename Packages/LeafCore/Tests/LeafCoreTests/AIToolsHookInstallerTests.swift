import XCTest

@testable import LeafCore

final class AIToolsHookInstallerTests: XCTestCase {
    private var tempDir: URL!
    private var settingsURL: URL!

    override func setUp() async throws {
        // /tmp/ to stay well under sun_path limits (not strictly relevant here but consistent).
        tempDir = URL(
            fileURLWithPath: "/tmp/leaf-installer-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // We emulate ~/.claude/settings.json layout.
        let claudeDir = tempDir.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        settingsURL = claudeDir.appendingPathComponent("settings.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeInstaller(bundlePath: String = "/Applications/Leaf.app") -> AIToolsHookInstaller {
        AIToolsHookInstaller(
            settingsURL: settingsURL,
            bundlePath: bundlePath
        )
    }

    private func readSettingsJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Helper — extract the `command` string of the first inner hook of the
    /// first matcher block for `event` (or empty string if missing).
    private func firstCommand(in hooks: [String: Any], for event: String) -> String {
        let arr = hooks[event] as? [[String: Any]] ?? []
        guard let matcher = arr.first,
            let innerHooks = matcher["hooks"] as? [[String: Any]],
            let first = innerHooks.first,
            let cmd = first["command"] as? String
        else { return "" }
        return cmd
    }

    // MARK: - Install

    func testInstallFromMissingFileCreatesFiveLeafEntries() throws {
        let installer = makeInstaller()
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        XCTAssertEqual(try installer.install(), .ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.path))

        let json = try readSettingsJSON()
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PreToolUse"])
        XCTAssertNotNil(hooks["PostToolUse"])
        XCTAssertNotNil(hooks["UserPromptSubmit"])
        XCTAssertNotNil(hooks["SessionEnd"])
        XCTAssertNotNil(hooks["PreCompact"])
        XCTAssertEqual(installer.currentStatus(), .installed)
    }

    func testInstallPreservesUserForeignHook() throws {
        // User pre-installed a foreign PostToolUse hook (e.g. prettier autoformat).
        let initial = #"""
            {"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"/usr/local/bin/prettier"}]}]}}
            """#
        try Data(initial.utf8).write(to: settingsURL)

        let installer = makeInstaller()
        XCTAssertEqual(try installer.install(), .ok)

        let json = try readSettingsJSON()
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let postToolUse = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        let allCommands = postToolUse.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(allCommands.contains("/usr/local/bin/prettier"), "user prettier hook preserved")
        XCTAssertTrue(allCommands.contains(where: { $0.contains("leaf-hook-bridge") }), "Leaf hook added")
    }

    func testInstallIsIdempotent() throws {
        let installer = makeInstaller()
        _ = try installer.install()
        _ = try installer.install()  // second time should not duplicate Leaf entries

        let json = try readSettingsJSON()
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        for eventName in ["PreToolUse", "PostToolUse", "UserPromptSubmit", "SessionEnd", "PreCompact"] {
            let arr = try XCTUnwrap(hooks[eventName] as? [[String: Any]])
            let leafEntries = arr.filter { matcher in
                let innerHooks = matcher["hooks"] as? [[String: Any]] ?? []
                return innerHooks.contains { ($0["command"] as? String)?.contains("leaf-hook-bridge") == true }
            }
            XCTAssertEqual(leafEntries.count, 1, "\(eventName) has exactly 1 Leaf matcher (no duplicates)")
        }
    }

    // MARK: - Uninstall

    func testUninstallRemovesOnlyLeafEntries() throws {
        // Setup: install Leaf, then add user foreign hook.
        let installer = makeInstaller()
        _ = try installer.install()
        // Inject a foreign user hook.
        var json = try readSettingsJSON()
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        var postToolUse = hooks["PostToolUse"] as? [[String: Any]] ?? []
        postToolUse.append([
            "matcher": "Write",
            "hooks": [["type": "command", "command": "/usr/local/bin/format"]],
        ])
        hooks["PostToolUse"] = postToolUse
        json["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: settingsURL)

        // Uninstall.
        XCTAssertEqual(try installer.uninstall(), .ok)

        let after = try readSettingsJSON()
        let afterHooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        // Only PostToolUse should survive (with user's foreign hook).
        XCTAssertNotNil(afterHooks["PostToolUse"])
        XCTAssertNil(afterHooks["PreToolUse"], "Leaf-only event removed")
        XCTAssertNil(afterHooks["UserPromptSubmit"])
        XCTAssertNil(afterHooks["SessionEnd"])
        XCTAssertNil(afterHooks["PreCompact"])
        let postToolUseAfter = try XCTUnwrap(afterHooks["PostToolUse"] as? [[String: Any]])
        let commands = postToolUseAfter.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertFalse(commands.contains(where: { $0.contains("leaf-hook-bridge") }), "Leaf entries removed")
        XCTAssertTrue(commands.contains("/usr/local/bin/format"), "user hook preserved")
        XCTAssertEqual(installer.currentStatus(), .notInstalled)
    }

    func testUninstallFromEmptyOrMissingIsNoop() throws {
        let installer = makeInstaller()
        // File doesn't exist.
        XCTAssertEqual(try installer.uninstall(), .ok)
        // Status reads as notInstalled (still no file).
        XCTAssertEqual(installer.currentStatus(), .notInstalled)
    }

    // MARK: - Status / drift

    func testCurrentStatusDetectsDrift() throws {
        // Install with one bundle path; query status with a different bundle path.
        let installerOld = makeInstaller(bundlePath: "/Applications/Leaf-Old.app")
        _ = try installerOld.install()

        let installerNew = makeInstaller(bundlePath: "/Applications/Leaf.app")
        XCTAssertEqual(
            installerNew.currentStatus(), .drifted,
            "different bundle path → drifted state")
    }

    // MARK: - Robustness

    func testInstallRecoversFromMalformedExistingFile() throws {
        try Data("not valid json {{{".utf8).write(to: settingsURL)
        let installer = makeInstaller()
        XCTAssertThrowsError(try installer.install()) { error in
            // Expected: throws on malformed input — user should see error
            // and manually fix or delete settings.json.
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "AIToolsHookInstaller")
            XCTAssertEqual(nsError.code, 3)
        }
    }

    func testInstallCreatesParentDirectoryIfMissing() throws {
        // Use a settings URL deeper than the existing claude-dir
        let deep =
            tempDir
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        let installer = AIToolsHookInstaller(settingsURL: deep, bundlePath: "/Applications/Leaf.app")
        XCTAssertEqual(try installer.install(), .ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: deep.path))
    }

    func testInstallCommandContainsEventName() throws {
        let installer = makeInstaller()
        _ = try installer.install()
        let json = try readSettingsJSON()
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        for event in ["PreToolUse", "PostToolUse", "UserPromptSubmit", "SessionEnd", "PreCompact"] {
            let cmd = firstCommand(in: hooks, for: event)
            XCTAssertTrue(
                cmd.hasSuffix(" \(event)"),
                "Command ends with event name for \(event); got: \(cmd)")
            XCTAssertTrue(
                cmd.contains("leaf-hook-bridge"),
                "Command points at bridge for \(event); got: \(cmd)")
        }
    }

    func testPreCompactMatcherIsManualPipeAuto() throws {
        let installer = makeInstaller()
        _ = try installer.install()
        let json = try readSettingsJSON()
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        let preCompact = hooks["PreCompact"] as? [[String: Any]] ?? []
        XCTAssertEqual(preCompact.first?["matcher"] as? String, "manual|auto")
    }
}
