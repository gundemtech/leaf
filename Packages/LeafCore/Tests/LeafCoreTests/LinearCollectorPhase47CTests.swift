// Phase 4.7.C — priority/label/assignee/cycle/estimate transitions + project-update,
// document-edited, initiative-observed + end-to-end Phase 4.7.C batch integration.
// Split from LinearCollectorTests.swift for type_body_length / file_length.

import XCTest
import os
import class GRDB.Row

@testable import LeafCore

final class LinearCollectorPhase47CTests: XCTestCase {
    private typealias Support = LinearCollectorTestSupport
    private typealias MockLinearGraphQLProvider = LinearCollectorTestSupport.MockLinearGraphQLProvider

    private var tempDir: URL!
    private var dbURL: URL!
    private var logger: Logger { LinearCollectorTestSupport.logger }

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-linear-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func insertFreshIntegration(
        db: Database, workspaceID: String = "ws-1",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws {
        try Support.insertFreshIntegration(db: db, workspaceID: workspaceID, expiresAt: expiresAt)
    }

    private func makeIsolatedSuiteName() -> String {
        Support.makeIsolatedSuiteName()
    }

    // MARK: - Phase 4.7.C — priority transitions

    /// Batch с одним priorityTransitions snap → tick emit'ит linear_priority_changed
    /// event с правильным payload shape (signal=action, raw int values, history_id).
    func testTickEmitsPriorityTransitionEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let prioritySnap = LinearPriorityTransitionSnapshot(
            issueKey: "LEA-1",
            historyId: "hist-prio-1",
            transitionAtMs: cursorMs,
            fromPriority: 3,
            toPriority: 1
        )
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-1", title: "Topic", status: "In Progress",
                        project: "", teamKey: "LEA", updatedAtMs: cursorMs
                    )
                ],
                cursorMs: cursorMs,
                priorityTransitions: [prioritySnap]
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let priorityEvent = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "linear_priority_changed" }
        )
        XCTAssertEqual(priorityEvent.payload["issue_key"], "LEA-1")
        XCTAssertEqual(priorityEvent.payload["history_id"], "hist-prio-1")
        XCTAssertEqual(priorityEvent.payload["from_priority"], "3")
        XCTAssertEqual(priorityEvent.payload["to_priority"], "1")
        XCTAssertEqual(priorityEvent.payload["source"], "linear")
        XCTAssertEqual(priorityEvent.signalType, .action)
    }

    /// Mixed batch: 2 added + 1 removed snap'а → 3 events с правильными kind'ами.
    func testTickEmitsLabelAddedAndRemovedEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let snaps = [
            LinearLabelTransitionSnapshot(
                issueKey: "LEA-200", historyId: "hist-lbl-1",
                transitionAtMs: cursorMs, kind: .added,
                labelId: "lbl-1", labelName: "bug"
            ),
            LinearLabelTransitionSnapshot(
                issueKey: "LEA-200", historyId: "hist-lbl-1",
                transitionAtMs: cursorMs, kind: .added,
                labelId: "lbl-2", labelName: "p1"
            ),
            LinearLabelTransitionSnapshot(
                issueKey: "LEA-200", historyId: "hist-lbl-1",
                transitionAtMs: cursorMs, kind: .removed,
                labelId: "lbl-3", labelName: "wontfix"
            ),
        ]
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-200", title: "Topic", status: "In Progress",
                        project: "", teamKey: "LEA", updatedAtMs: cursorMs
                    )
                ],
                cursorMs: cursorMs,
                labelTransitions: snaps
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let added = stored.filter { $0.payload["event_kind"] == "linear_label_added" }
        let removed = stored.filter { $0.payload["event_kind"] == "linear_label_removed" }
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(Set(added.compactMap { $0.payload["label_id"] }), ["lbl-1", "lbl-2"])
        XCTAssertEqual(removed.first?.payload["label_id"], "lbl-3")
        XCTAssertEqual(removed.first?.payload["issue_key"], "LEA-200")
    }

    /// Phase 4.7.C — assignee event с bucket enum + no raw IDs leaked.
    func testTickEmitsAssigneeTransitionEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let snap = LinearAssigneeTransitionSnapshot(
            issueKey: "LEA-300",
            historyId: "hist-asg-1",
            transitionAtMs: cursorMs,
            bucket: .reassignedSelfToOther
        )
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-300", title: "Topic", status: "In Progress",
                        project: "", teamKey: "LEA", updatedAtMs: cursorMs
                    )
                ],
                cursorMs: cursorMs,
                assigneeTransitions: [snap]
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let asgn = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_assignee_changed" })
        XCTAssertEqual(asgn.payload["issue_key"], "LEA-300")
        XCTAssertEqual(asgn.payload["history_id"], "hist-asg-1")
        XCTAssertEqual(asgn.payload["bucket"], "reassigned_self_to_other")
        // ADR-010 sentinel: payload не должен содержать from/to ID полей вообще.
        XCTAssertNil(asgn.payload["from_assignee_id"], "raw IDs не покидают provider")
        XCTAssertNil(asgn.payload["to_assignee_id"])
    }

    /// Phase 4.7.C — cycle transition event с правильным payload (move scenario).
    func testTickEmitsCycleTransitionEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let snap = LinearCycleTransitionSnapshot(
            issueKey: "LEA-400", historyId: "hist-cyc-1",
            transitionAtMs: cursorMs,
            fromCycleId: "cyc-1", fromCycleName: "Sprint 41",
            toCycleId: "cyc-2", toCycleName: "Sprint 42"
        )
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-400", title: "Topic", status: "In Progress",
                        project: "", teamKey: "LEA", updatedAtMs: cursorMs
                    )
                ],
                cursorMs: cursorMs,
                cycleTransitions: [snap]
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let cyc = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_cycle_changed" })
        XCTAssertEqual(cyc.payload["issue_key"], "LEA-400")
        XCTAssertEqual(cyc.payload["from_cycle_id"], "cyc-1")
        XCTAssertEqual(cyc.payload["from_cycle_name"], "Sprint 41")
        XCTAssertEqual(cyc.payload["to_cycle_id"], "cyc-2")
        XCTAssertEqual(cyc.payload["to_cycle_name"], "Sprint 42")
    }

    /// Phase 4.7.C — cycle transition payload omits nil sides (added/removed).
    func testTickEmitsCycleTransitionEventWithOmittedNilSides() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        // "Added to cycle" — fromCycle nil, toCycle populated.
        let snap = LinearCycleTransitionSnapshot(
            issueKey: "LEA-401", historyId: "hist-cyc-add",
            transitionAtMs: cursorMs,
            fromCycleId: nil, fromCycleName: nil,
            toCycleId: "cyc-X", toCycleName: "Sprint X"
        )
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-401", title: "Topic", status: "In Progress",
                        project: "", teamKey: "LEA", updatedAtMs: cursorMs
                    )
                ],
                cursorMs: cursorMs,
                cycleTransitions: [snap]
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let cyc = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_cycle_changed" })
        XCTAssertNil(cyc.payload["from_cycle_id"], "nil from → ключ omitted")
        XCTAssertNil(cyc.payload["from_cycle_name"])
        XCTAssertEqual(cyc.payload["to_cycle_id"], "cyc-X")
        XCTAssertEqual(cyc.payload["to_cycle_name"], "Sprint X")
    }

    /// Phase 4.7.C — estimate transition event с правильным payload.
    func testTickEmitsEstimateTransitionEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let snap = LinearEstimateTransitionSnapshot(
            issueKey: "LEA-500", historyId: "hist-est-1",
            transitionAtMs: cursorMs,
            fromEstimate: 3.0, toEstimate: 5.0
        )
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-500", title: "Topic", status: "In Progress",
                        project: "", teamKey: "LEA", updatedAtMs: cursorMs
                    )
                ],
                cursorMs: cursorMs,
                estimateTransitions: [snap]
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let est = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_estimate_changed" })
        XCTAssertEqual(est.payload["issue_key"], "LEA-500")
        XCTAssertEqual(est.payload["history_id"], "hist-est-1")
        XCTAssertEqual(est.payload["from_estimate"], "3.0")
        XCTAssertEqual(est.payload["to_estimate"], "5.0")
    }

    /// Estimate added (nil → 5) — payload omits from_estimate.
    func testTickEmitsEstimateAddedEventWithOmittedFrom() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let snap = LinearEstimateTransitionSnapshot(
            issueKey: "LEA-501", historyId: "hist-est-add",
            transitionAtMs: cursorMs,
            fromEstimate: nil, toEstimate: 8.0
        )
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-501", title: "Topic", status: "In Progress",
                        project: "", teamKey: "LEA", updatedAtMs: cursorMs
                    )
                ],
                cursorMs: cursorMs,
                estimateTransitions: [snap]
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let est = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_estimate_changed" })
        XCTAssertNil(est.payload["from_estimate"], "nil from → omit ключа")
        XCTAssertEqual(est.payload["to_estimate"], "8.0")
    }

    /// Phase 4.7.C — ProjectUpdate authored event с правильным payload.
    func testTickEmitsProjectUpdateAuthoredEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let pu = LinearProjectUpdateSnapshot(
            updateId: "pu-1",
            createdAtMs: cursorMs,
            projectId: "proj-A", projectName: "Leaf",
            health: "onTrack"
        )
        await provider.setBatch(
            LinearIssueBatch(
                issues: [],
                cursorMs: cursorMs,
                projectUpdates: [pu]
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let pu2 = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_project_update_authored" })
        XCTAssertEqual(pu2.payload["update_id"], "pu-1")
        XCTAssertEqual(pu2.payload["project_id"], "proj-A")
        XCTAssertEqual(pu2.payload["project_name"], "Leaf")
        XCTAssertEqual(pu2.payload["health"], "onTrack")
    }

    /// Empty projectUpdates → no event.
    func testTickDoesNotEmitProjectUpdateEventWhenEmpty() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        await provider.setBatch(LinearIssueBatch(issues: [], cursorMs: cursorMs))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        XCTAssertNil(
            stored.first { $0.payload["event_kind"] == "linear_project_update_authored" }
        )
    }

    /// Phase 4.7.C — Document edited event с правильным payload.
    func testTickEmitsDocumentEditedEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let doc = LinearDocumentSnapshot(
            documentId: "doc-1",
            updatedAtMs: nowMs,
            projectId: "proj-A", projectName: "Leaf",
            title: "Q4 Roadmap"
        )
        await provider.setBatch(
            LinearIssueBatch(
                issues: [], cursorMs: nowMs,
                documents: [doc]
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let de = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_document_edited" })
        XCTAssertEqual(de.payload["document_id"], "doc-1")
        XCTAssertEqual(de.payload["title"], "Q4 Roadmap")
        XCTAssertEqual(de.payload["project_id"], "proj-A")
        XCTAssertEqual(de.payload["project_name"], "Leaf")
    }

    /// Standalone document — без project info.
    func testTickEmitsDocumentEditedEventStandalone() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let doc = LinearDocumentSnapshot(
            documentId: "doc-2",
            updatedAtMs: nowMs,
            projectId: nil, projectName: nil,
            title: "Standalone"
        )
        await provider.setBatch(
            LinearIssueBatch(
                issues: [], cursorMs: nowMs,
                documents: [doc]
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let de = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_document_edited" })
        XCTAssertEqual(de.payload["document_id"], "doc-2")
        XCTAssertEqual(de.payload["title"], "Standalone")
        XCTAssertNil(de.payload["project_id"])
        XCTAssertNil(de.payload["project_name"])
    }

    /// Phase 4.7.C — Initiative observed event с signal_type=.context.
    func testTickEmitsInitiativeObservedEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let init1 = LinearInitiativeSnapshot(
            initiativeId: "init-1",
            name: "Q4 Goals",
            status: "Active",
            observedAtMs: nowMs
        )
        await provider.setBatch(
            LinearIssueBatch(
                issues: [], cursorMs: nowMs,
                initiatives: [init1]
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let init2 = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_initiative_observed" })
        XCTAssertEqual(init2.payload["initiative_id"], "init-1")
        XCTAssertEqual(init2.payload["name"], "Q4 Goals")
        XCTAssertEqual(init2.payload["status"], "Active")
        XCTAssertEqual(init2.signalType, .context, "membership snapshot per tick — context signal")
    }

    /// Initiative без status — payload omits status field.
    func testTickEmitsInitiativeObservedEventWithNilStatus() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let snap = LinearInitiativeSnapshot(
            initiativeId: "init-2", name: "Beta", status: nil, observedAtMs: nowMs
        )
        await provider.setBatch(
            LinearIssueBatch(
                issues: [], cursorMs: nowMs,
                initiatives: [snap]
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))
        let i = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "linear_initiative_observed" })
        XCTAssertEqual(i.payload["initiative_id"], "init-2")
        XCTAssertNil(i.payload["status"])
    }

    // MARK: - Phase 4.7.C — end-to-end collector emission integration

    // C-12 integration: batch со всеми Phase 4.7.C snapshot flavors → assert все
    // expected event_kinds присутствуют в DB, count'ы матчат, signal types
    // корректные, sentinel string не просачивается ни в один payload.
    //
    // Длинное тело — build всех 12 snapshot flavors + tick + assert по всем
    // event_kinds + sentinel walk. Декомпозиция в helpers разбила бы trace
    // «какой snapshot какой event эмитит».
    // swiftlint:disable:next function_body_length
    func testTick_FullPhase47CBatch_EmitsAllEventKinds() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let sentinel = "SHOULD_NOT_LEAK_ADR010"

        let issue = LinearIssueSnapshot(
            issueKey: "LEA-INT", title: "Topic", status: "In Progress",
            project: "Leaf", teamKey: "LEA", updatedAtMs: nowMs
        )
        let stateTransition = LinearStateTransitionSnapshot(
            issueKey: "LEA-INT", historyId: "h-state",
            transitionAtMs: nowMs,
            fromStateName: "Unstarted", fromStateType: "unstarted",
            toStateName: "In Progress", toStateType: "started"
        )
        let priority = LinearPriorityTransitionSnapshot(
            issueKey: "LEA-INT", historyId: "h-prio",
            transitionAtMs: nowMs, fromPriority: 3, toPriority: 1
        )
        let labelAdded = LinearLabelTransitionSnapshot(
            issueKey: "LEA-INT", historyId: "h-lbl",
            transitionAtMs: nowMs, kind: .added,
            labelId: "lbl-A", labelName: "bug"
        )
        let labelRemoved = LinearLabelTransitionSnapshot(
            issueKey: "LEA-INT", historyId: "h-lbl",
            transitionAtMs: nowMs, kind: .removed,
            labelId: "lbl-B", labelName: "wontfix"
        )
        let assignee = LinearAssigneeTransitionSnapshot(
            issueKey: "LEA-INT", historyId: "h-asg",
            transitionAtMs: nowMs, bucket: .reassignedSelfToOther
        )
        let cycle = LinearCycleTransitionSnapshot(
            issueKey: "LEA-INT", historyId: "h-cyc",
            transitionAtMs: nowMs,
            fromCycleId: "cyc-1", fromCycleName: "Sprint 41",
            toCycleId: "cyc-2", toCycleName: "Sprint 42"
        )
        let estimate = LinearEstimateTransitionSnapshot(
            issueKey: "LEA-INT", historyId: "h-est",
            transitionAtMs: nowMs, fromEstimate: 3.0, toEstimate: 5.0
        )
        let projectUpdate = LinearProjectUpdateSnapshot(
            updateId: "pu-1", createdAtMs: nowMs,
            projectId: "proj-A", projectName: "Leaf",
            health: "onTrack"
        )
        let document = LinearDocumentSnapshot(
            documentId: "doc-1", updatedAtMs: nowMs,
            projectId: "proj-A", projectName: "Leaf",
            title: "Q4 Roadmap"
        )
        let initiative = LinearInitiativeSnapshot(
            initiativeId: "init-1", name: "Q4 Goals",
            status: "Active", observedAtMs: nowMs
        )

        await provider.setBatch(
            LinearIssueBatch(
                issues: [issue],
                cursorMs: nowMs,
                transitions: [stateTransition],
                priorityTransitions: [priority],
                labelTransitions: [labelAdded, labelRemoved],
                assigneeTransitions: [assignee],
                cycleTransitions: [cycle],
                estimateTransitions: [estimate],
                projectUpdates: [projectUpdate],
                documents: [document],
                initiatives: [initiative]
            ))

        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7,
            logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSinceNow: -3600),
                end: Date(timeIntervalSinceNow: 3600)
            ))

        // Expected breakdown (per LinearCollector.performTick emission order):
        //   1× issue_updated, 1× status_transition, 1× linear_priority_changed,
        //   2× linear_label_added/removed (1+1), 1× linear_assignee_changed,
        //   1× linear_cycle_changed, 1× linear_estimate_changed,
        //   1× linear_project_update_authored, 1× linear_document_edited,
        //   1× linear_initiative_observed, 1× linear_assigned_workload_pulse.
        // No comment events (commentCountInWindow=0), no cycle progress
        // (batch.cycles empty).
        let kinds = Dictionary(grouping: stored, by: { $0.payload["event_kind"] ?? "?" })
            .mapValues { $0.count }
        XCTAssertEqual(kinds["issue_updated"], 1)
        XCTAssertEqual(kinds["status_transition"], 1)
        XCTAssertEqual(kinds["linear_priority_changed"], 1)
        XCTAssertEqual(kinds["linear_label_added"], 1)
        XCTAssertEqual(kinds["linear_label_removed"], 1)
        XCTAssertEqual(kinds["linear_assignee_changed"], 1)
        XCTAssertEqual(kinds["linear_cycle_changed"], 1)
        XCTAssertEqual(kinds["linear_estimate_changed"], 1)
        XCTAssertEqual(kinds["linear_project_update_authored"], 1)
        XCTAssertEqual(kinds["linear_document_edited"], 1)
        XCTAssertEqual(kinds["linear_initiative_observed"], 1)
        XCTAssertEqual(kinds["linear_assigned_workload_pulse"], 1)
        XCTAssertEqual(
            stored.count, 12,
            "Phase 4.7.C full batch → 12 events; got: \(kinds)")

        // Signal type sanity: actions vs context.
        let actionKinds: Set<String> = [
            "issue_updated", "status_transition", "linear_priority_changed",
            "linear_label_added", "linear_label_removed",
            "linear_assignee_changed", "linear_cycle_changed",
            "linear_estimate_changed", "linear_project_update_authored",
            "linear_document_edited",
        ]
        let contextKinds: Set<String> = [
            "linear_initiative_observed", "linear_assigned_workload_pulse",
        ]
        for ev in stored {
            let kind = ev.payload["event_kind"] ?? ""
            if actionKinds.contains(kind) {
                XCTAssertEqual(
                    ev.signalType, .action,
                    "\(kind) must be .action signal")
            } else if contextKinds.contains(kind) {
                XCTAssertEqual(
                    ev.signalType, .context,
                    "\(kind) must be .context signal")
            }
        }

        // ADR-010 sentinel walk: ни один payload не содержит sentinel.
        // (Snapshots не содержат sentinel — это integration test, not response
        // contamination — но sanity assert для regression catch'ей.)
        for ev in stored {
            for (k, v) in ev.payload {
                XCTAssertFalse(
                    v.contains(sentinel),
                    "ADR-010: payload[\(k)]=\"\(v)\" не должен содержать sentinel")
            }
        }
    }
}
