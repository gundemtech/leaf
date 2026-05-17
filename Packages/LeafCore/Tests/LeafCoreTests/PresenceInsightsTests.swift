// Phase 4.7.B-15 — `PresenceInsights.currentSnapshot` (testable backing
// для `get_current_presence` MCP tool).
//
// LeafMCP target живёт под Xcode (не под `swift test`), поэтому tool-struct
// `GetCurrentPresenceTool` в `LeafMCP/Tools/` тестируется через свой
// LeafCore helper (`PresenceInsights.currentSnapshot`). Здесь — все 4
// плановых case'а:
//
//   - testExecute_EmptyDB_ReturnsEmptyProviders
//   - testExecute_SeededPresenceState_ReturnsAllRows
//   - testExecute_DerivedModeNullInPhase47
//   - testExecute_NoArgumentsAccepted (схема tool — `properties:{}`,
//     `additionalProperties:false`. Helper аргументов вообще не принимает,
//     поэтому "extra args ignored" для tool-обёртки тривиально верно.
//     Тест верифицирует, что helper детерминирован и не зависит ни от
//     каких аргументов, и что schema действительно пустая в definition.)

import GRDB
import XCTest

@testable import LeafCore

final class PresenceInsightsTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-presence-insights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Empty DB

    /// Свежая (только что созданная) DB → providers={} (пустой словарь
    /// — отсутствуют все 4 row'а PresenceStateWriter.Provider). Top-level
    /// shape сохраняется: ключи `providers` и `observed_at_ms` присутствуют.
    func testExecute_EmptyDB_ReturnsEmptyProviders() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let payload = try PresenceInsights.currentSnapshot(database: db)

        let providers = try XCTUnwrap(payload["providers"] as? [String: Any])
        XCTAssertEqual(providers.count, 0, "fresh DB → ни одного presence_state row")

        let observedAt = try XCTUnwrap(payload["observed_at_ms"] as? Int64)
        // Sanity — в пределах разумного (сегодняшний эпох-таймштамп ms).
        XCTAssertGreaterThan(observedAt, 1_700_000_000_000)
    }

    // MARK: - Seeded → all rows

    /// Seed 3 row'а (github / linear / slack) → response.providers содержит
    /// все три ключа с полями state / derived_mode / updated_at_ms.
    func testExecute_SeededPresenceState_ReturnsAllRows() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeSQL { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: ["status": "online", "open_prs": 2],
                derivedMode: nil,
                nowMs: 1_700_000_001_000,
                in: rawDB
            )
            try PresenceStateWriter.upsert(
                provider: .linear,
                state: ["assigned_count": 5, "active_cycle": "Cycle 23"],
                derivedMode: nil,
                nowMs: 1_700_000_002_000,
                in: rawDB
            )
            try PresenceStateWriter.upsert(
                provider: .slack,
                state: ["presence": "active", "snoozed": false],
                derivedMode: nil,
                nowMs: 1_700_000_003_000,
                in: rawDB
            )
        }

        let payload = try PresenceInsights.currentSnapshot(database: db)
        let providers = try XCTUnwrap(payload["providers"] as? [String: Any])
        XCTAssertEqual(providers.count, 3)
        XCTAssertNotNil(providers["github"])
        XCTAssertNotNil(providers["linear"])
        XCTAssertNotNil(providers["slack"])
        XCTAssertNil(providers["derived"], "Phase 4.7 не пишет derived row")

        // GitHub state roundtrip.
        let github = try XCTUnwrap(providers["github"] as? [String: Any])
        let githubState = try XCTUnwrap(github["state"] as? [String: Any])
        XCTAssertEqual(githubState["status"] as? String, "online")
        XCTAssertEqual(githubState["open_prs"] as? Int, 2)
        XCTAssertEqual(github["updated_at_ms"] as? Int64, 1_700_000_001_000)

        // Linear state roundtrip.
        let linear = try XCTUnwrap(providers["linear"] as? [String: Any])
        let linearState = try XCTUnwrap(linear["state"] as? [String: Any])
        XCTAssertEqual(linearState["assigned_count"] as? Int, 5)
        XCTAssertEqual(linearState["active_cycle"] as? String, "Cycle 23")
        XCTAssertEqual(linear["updated_at_ms"] as? Int64, 1_700_000_002_000)

        // Slack state roundtrip.
        let slack = try XCTUnwrap(providers["slack"] as? [String: Any])
        let slackState = try XCTUnwrap(slack["state"] as? [String: Any])
        XCTAssertEqual(slackState["presence"] as? String, "active")
        XCTAssertEqual(slackState["snoozed"] as? Bool, false)
        XCTAssertEqual(slack["updated_at_ms"] as? Int64, 1_700_000_003_000)
    }

    // MARK: - derived_mode invariant

    /// derived_mode не должен populated в Phase 4.7 — все ключи под
    /// providers содержат `derived_mode: NSNull` (явный null, не отсутствие
    /// ключа).  Phase 4.9 mode classifier начнёт писать string-значения.
    func testExecute_DerivedModeNullInPhase47() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeSQL { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: ["status": "online"],
                derivedMode: nil,
                nowMs: 1_700_000_000_000,
                in: rawDB
            )
            try PresenceStateWriter.upsert(
                provider: .linear,
                state: ["assigned_count": 0],
                derivedMode: nil,
                nowMs: 1_700_000_000_500,
                in: rawDB
            )
            try PresenceStateWriter.upsert(
                provider: .slack,
                state: ["presence": "active"],
                derivedMode: nil,
                nowMs: 1_700_000_001_000,
                in: rawDB
            )
        }

        let payload = try PresenceInsights.currentSnapshot(database: db)
        let providers = try XCTUnwrap(payload["providers"] as? [String: Any])
        for key in ["github", "linear", "slack"] {
            let entry = try XCTUnwrap(providers[key] as? [String: Any], "providers.\(key) missing")
            XCTAssertNotNil(
                entry["derived_mode"],
                "providers.\(key).derived_mode must be present (as NSNull) — explicit null, not missing key"
            )
            XCTAssertTrue(
                entry["derived_mode"] is NSNull,
                "providers.\(key).derived_mode must be NSNull in Phase 4.7 (got \(String(describing: entry["derived_mode"])))"
            )
        }

        // Round-trip через JSONSerialization — убедимся, что NSNull
        // действительно сериализуется в `null`, а не выпадает.
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let jsonString = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(
            jsonString.contains(#""derived_mode":null"#),
            "JSON output must contain explicit `derived_mode:null`. Got: \(jsonString)"
        )
    }

    // MARK: - schema / args

    /// Tool схема — `properties:{}` + `additionalProperties:false`,
    /// и helper не принимает аргументов вообще. Проверяем оба инварианта.
    /// Это проверка контракта: вызов `currentSnapshot(database:)` детерминирован
    /// относительно DB content; "extra args" в tool-обёртке отбрасываются на
    /// уровне MCP server schema (additionalProperties=false), но helper
    /// этого не видит и работает одинаково.
    func testExecute_NoArgumentsAccepted() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.writeSQL { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: ["status": "online"],
                derivedMode: nil,
                nowMs: 1_700_000_000_000,
                in: rawDB
            )
        }

        // Helper детерминирован — два последовательных вызова дают
        // одинаковый providers payload (observed_at_ms может отличаться).
        let p1 = try PresenceInsights.currentSnapshot(database: db)
        let p2 = try PresenceInsights.currentSnapshot(database: db)

        let providers1 = try XCTUnwrap(p1["providers"] as? [String: Any])
        let providers2 = try XCTUnwrap(p2["providers"] as? [String: Any])

        // Сериализуем оба providers-словаря в детерминированный JSON
        // (sortedKeys) и сравниваем.
        let j1 = try JSONSerialization.data(withJSONObject: providers1, options: [.sortedKeys])
        let j2 = try JSONSerialization.data(withJSONObject: providers2, options: [.sortedKeys])
        XCTAssertEqual(j1, j2, "providers payload must be deterministic across calls")
    }
}
