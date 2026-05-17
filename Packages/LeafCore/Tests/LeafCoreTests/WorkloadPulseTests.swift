// Phase 4.7.B-16 — `PresenceInsights.workloadPulse` (testable backing
// для `get_workload_pulse` MCP tool).
//
// LeafMCP target живёт под Xcode (не под `swift test`), поэтому tool-struct
// `GetWorkloadPulseTool` в `LeafMCP/Tools/` тестируется через свой
// LeafCore helper. Здесь — все 3 плановых case'а:
//
//   - testExecute_PeriodToday_AggregatesCorrectly
//   - testExecute_NoData_ReturnsZeros
//   - testExecute_InvalidPeriod_DefaultsToToday
//
// "Invalid period" handled на tool-обёртке (permissive parse → defaults
// to today). На уровне helper'а enum strict — InvalidPeriod test
// верифицирует, что `WorkloadPulsePeriod(rawValue:)` returns nil для
// невалидного raw, и что .today как default produces валидный payload.

import GRDB
import XCTest

@testable import LeafCore

final class WorkloadPulseTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-workload-pulse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeMentionEvent(channel: String, count: Int, atMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": "slack_mention_received_aggregate",
                "channel": channel,
                "count": String(count),
                "period_start_ms": String(atMs - 1000),
                "period_end_ms": String(atMs),
            ]
        )
    }

    private func makeFileUploadEvent(count: Int, atMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": "slack_file_uploaded_aggregate",
                "count": String(count),
                "image_count": "0",
                "code_count": "0",
                "doc_count": "0",
                "other_count": String(count),
                "period_start_ms": String(atMs - 1000),
                "period_end_ms": String(atMs),
            ]
        )
    }

    private func makeActionsRunEvent(status: String, atMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "github",
                "event_kind": "gh_actions_run_initiated",
                "run_id": "1",
                "repo": "octocat/Hello-World",
                "workflow_name": "ci.yml",
                "event": "push",
                "status": status,
                "created_at_ms": String(atMs),
            ]
        )
    }

    // MARK: - testExecute_NoData_ReturnsZeros

    /// Свежая (только что созданная) DB → все subkey'и со значениями-по-умолчанию:
    /// 0 для счётчиков, "none" для top_priority, "unknown" для native_presence,
    /// false для dnd_active, `{}` для current_cycle. Top-level keys присутствуют.
    func testExecute_NoData_ReturnsZeros() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let payload = try PresenceInsights.workloadPulse(database: db, period: .today)

        let github = try XCTUnwrap(payload["github"] as? [String: Any])
        XCTAssertEqual(github["prs_awaiting_my_review"] as? Int, 0)
        XCTAssertEqual(github["my_open_prs"] as? Int, 0)
        XCTAssertEqual(github["notifications_unread"] as? Int, 0)
        XCTAssertEqual(github["actions_runs_in_progress"] as? Int, 0)

        let linear = try XCTUnwrap(payload["linear"] as? [String: Any])
        XCTAssertEqual(linear["started_count"] as? Int, 0)
        XCTAssertEqual(linear["top_priority"] as? String, "none")
        let cycle = try XCTUnwrap(linear["current_cycle"] as? [String: Any])
        XCTAssertTrue(cycle.isEmpty, "current_cycle should be `{}` when no cycle data")

        let slack = try XCTUnwrap(payload["slack"] as? [String: Any])
        XCTAssertEqual(slack["mentions_received_today"] as? Int, 0)
        XCTAssertEqual(slack["files_uploaded_today"] as? Int, 0)
        XCTAssertEqual(slack["dnd_active"] as? Bool, false)
        XCTAssertEqual(slack["native_presence"] as? String, "unknown")

        XCTAssertEqual(payload["period"] as? String, "today")
        let observedAt = try XCTUnwrap(payload["observed_at_ms"] as? Int64)
        XCTAssertGreaterThan(observedAt, 1_700_000_000_000)
    }

    // MARK: - testExecute_PeriodToday_AggregatesCorrectly

    // Seed presence_state.{github,linear,slack} composite + events:
    // 2 mention events (count=3 each, today) + 1 file-upload (count=5, today)
    // + 1 actions_run_initiated в in_progress (24h window).
    // → workloadPulse('today') aggregates корректно.
    //
    // Длинное тело — seed→act→assert последовательность 7 нумерованных шагов
    // для трёх провайдеров одновременно. Декомпозиция в helpers скрыла бы
    // читаемость теста (порядок шагов исчезает за вызовами).
    // swiftlint:disable:next function_body_length
    func testExecute_PeriodToday_AggregatesCorrectly() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        // 1. Seed presence_state.github composite.
        try db.writeSQL { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: [
                    "prs_awaiting_my_review": 3,
                    "my_open_prs": 5,
                    "notifications_unread": 12,
                    "active_repos_count": 2,
                    "contributions_today": 7,
                ],
                derivedMode: nil,
                nowMs: 1_700_000_001_000,
                in: rawDB
            )
            try PresenceStateWriter.upsert(
                provider: .linear,
                state: [
                    "started_issues_count": 4,
                    "top_priority": "high",
                    "current_cycle": [
                        "team_id": "TEAM",
                        "team_name": "Eng",
                        "cycle_id": "CYCLE",
                        "cycle_name": "Sprint 27",
                        "completed_pct": 60.0,
                        "days_remaining": 3,
                        "scope_count": 10,
                        "starts_at_ms": 1_700_000_000_000,
                        "ends_at_ms": 1_700_500_000_000,
                    ] as [String: Any],
                    "all_team_cycles": [],
                    "last_touched_issue_id": "LEA-1",
                    "last_touched_ts": 0,
                ],
                derivedMode: nil,
                nowMs: 1_700_000_002_000,
                in: rawDB
            )
            try PresenceStateWriter.upsert(
                provider: .slack,
                state: [
                    "native_presence": "active",
                    "dnd": [
                        "is_active": false,
                        "snooze_until_ms": 0,
                        "next_dnd_start_ms": 0,
                        "next_dnd_end_ms": 0,
                    ] as [String: Any],
                    "status_emoji": "",
                    "status_expiration_ts": 0,
                    "in_huddle": false,
                    "huddle_channel": "",
                    "last_activity_channel": "general",
                    "mention_count_today": 0,
                    "file_count_today": 0,
                ],
                derivedMode: nil,
                nowMs: 1_700_000_003_000,
                in: rawDB
            )
        }

        // 2. Seed events с timestamp'ами в today (relative to now).
        // Используем `now` через Calendar.startOfDay для детерминированного теста.
        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        // Поставим events на todayStart + 1h, чтобы точно попасть в today window
        // и НЕ попасть в "до полуночи" edge.
        let eventTime = todayStart.addingTimeInterval(60 * 60)
        let eventMs = Int64(eventTime.timeIntervalSince1970 * 1000)

        let mention1 = makeMentionEvent(channel: "general", count: 3, atMs: eventMs)
        let mention2 = makeMentionEvent(channel: "random", count: 3, atMs: eventMs + 100)
        let fileUpload = makeFileUploadEvent(count: 5, atMs: eventMs + 200)
        let actionsRun = makeActionsRunEvent(status: "in_progress", atMs: eventMs + 300)

        try db.write([mention1, mention2, fileUpload, actionsRun])

        // 3. Call workloadPulse with period=today, now=now (для детерминизма).
        let payload = try PresenceInsights.workloadPulse(database: db, period: .today, now: now)

        // 4. Assert github subkeys correct.
        let github = try XCTUnwrap(payload["github"] as? [String: Any])
        XCTAssertEqual(github["prs_awaiting_my_review"] as? Int, 3)
        XCTAssertEqual(github["my_open_prs"] as? Int, 5)
        XCTAssertEqual(github["notifications_unread"] as? Int, 12)
        XCTAssertEqual(github["actions_runs_in_progress"] as? Int, 1)

        // 5. Assert linear subkeys correct.
        let linear = try XCTUnwrap(payload["linear"] as? [String: Any])
        XCTAssertEqual(linear["started_count"] as? Int, 4)
        XCTAssertEqual(linear["top_priority"] as? String, "high")
        let cycle = try XCTUnwrap(linear["current_cycle"] as? [String: Any])
        XCTAssertEqual(cycle["cycle_name"] as? String, "Sprint 27")
        // completed_pct после JSON roundtrip может быть Double или NSNumber —
        // unwrap'аем через NSNumber для robust сравнения.
        let completedPct = (cycle["completed_pct"] as? NSNumber)?.doubleValue
        XCTAssertEqual(completedPct, 60.0)
        XCTAssertEqual(cycle["days_remaining"] as? Int, 3)

        // 6. Assert slack subkeys correct.
        let slack = try XCTUnwrap(payload["slack"] as? [String: Any])
        XCTAssertEqual(slack["mentions_received_today"] as? Int, 6, "2 events × count=3 → SUM=6")
        XCTAssertEqual(slack["files_uploaded_today"] as? Int, 5, "1 event × count=5 → SUM=5")
        XCTAssertEqual(slack["dnd_active"] as? Bool, false)
        XCTAssertEqual(slack["native_presence"] as? String, "active")

        // 7. Period echo + observed_at_ms.
        XCTAssertEqual(payload["period"] as? String, "today")
        XCTAssertNotNil(payload["observed_at_ms"] as? Int64)
    }

    // MARK: - testExecute_InvalidPeriod_DefaultsToToday

    /// Permissive parse: на уровне tool-обёртки невалидный raw → defaults to
    /// today (verified в integration через GetWorkloadPulseTool, не здесь).
    /// На уровне helper'а проверяем: (a) `WorkloadPulsePeriod(rawValue:)`
    /// returns nil для невалидного, (b) helper с явным `period: .today` (как
    /// и сделает tool после fallback) produces валидный payload без падений.
    func testExecute_InvalidPeriod_DefaultsToToday() throws {
        // (a) Невалидный raw → nil.
        XCTAssertNil(PresenceInsights.WorkloadPulsePeriod(rawValue: "invalid_period"))
        XCTAssertNil(PresenceInsights.WorkloadPulsePeriod(rawValue: ""))
        XCTAssertNil(
            PresenceInsights.WorkloadPulsePeriod(rawValue: "yesterday"),
            "yesterday — TimelinePeriod value, не WorkloadPulsePeriod (расходящиеся enum'ы)")

        // (b) Валидный fallback на today produces non-throwing payload даже
        // на пустой DB (mirror к testExecute_NoData_ReturnsZeros, но проверяет
        // tool-style fallback path конкретно).
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let raw = "invalid_period"
        let parsed = PresenceInsights.WorkloadPulsePeriod(rawValue: raw) ?? .today
        XCTAssertEqual(parsed, .today, "fallback to today on invalid raw")

        let payload = try PresenceInsights.workloadPulse(database: db, period: parsed)
        XCTAssertEqual(payload["period"] as? String, "today")
        XCTAssertNotNil(payload["github"])
        XCTAssertNotNil(payload["linear"])
        XCTAssertNotNil(payload["slack"])
    }
}
