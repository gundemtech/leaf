// Track-1 D1 + Track-3 D1 — body / attachments / comment bodies in payload,
// empty-priority no-op, hot piggy-back emissions (comment reaction, relation,
// triage). Split from LinearCollectorTests.swift for type_body_length.

import XCTest
import os
import class GRDB.Row

@testable import LeafCore

final class LinearCollectorTrackD1AndD3Tests: XCTestCase {
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

    // MARK: - Phase Track-1 D1 — body / attachments / comment bodies in payload

    /// Track-1 D1: snapshot.description flows into events.payload["body"] key.
    /// Test MUST query issue_updated (existing event_kind), NOT linear_issue_updated.
    func testTick_PopulatesBodyPayloadKey_TrackD1() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let baseMs: Int64 = 1_700_000_000_000
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-D1", title: "OAuth refactor", status: "In Progress",
                        project: "Leaf", teamKey: "LEA", updatedAtMs: baseMs,
                        description: "Refactor OAuth refresh"
                    )
                ],
                cursorMs: baseMs
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
                start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
                end: Date(timeIntervalSince1970: TimeInterval(baseMs + 5000) / 1000)
            ))

        // Filter to issue_updated event (not workload_pulse)
        let issueEvent = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "issue_updated" && $0.payload["issue_key"] == "LEA-D1" },
            "Expected an issue_updated event for LEA-D1"
        )
        XCTAssertEqual(
            issueEvent.payload[Schema.EventPayloadKeys.body], "Refactor OAuth refresh",
            "Track-1 D1: description should appear as 'body' payload key")
        XCTAssertNil(
            issueEvent.payload[Schema.EventPayloadKeys.bodyTruncated],
            "Short body — body_truncated should not be set")
    }

    /// Track-1 D1: snapshot.attachments encode as JSON in payload["attachments_json"].
    func testTick_AttachmentsJSONShape_TrackD1() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let baseMs: Int64 = 1_700_000_001_000
        let attachments = [
            AttachmentMeta(name: "Design Spec", mime: "image/png", sizeBytes: 204800),
            AttachmentMeta(name: "PR Draft", mime: nil, sizeBytes: nil),
        ]
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-D1-att", title: "With attachments", status: "In Progress",
                        project: "Leaf", teamKey: "LEA", updatedAtMs: baseMs,
                        attachments: attachments
                    )
                ],
                cursorMs: baseMs
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
                start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
                end: Date(timeIntervalSince1970: TimeInterval(baseMs + 5000) / 1000)
            ))

        let issueEvent = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "issue_updated" && $0.payload["issue_key"] == "LEA-D1-att" }
        )
        let attachJson = try XCTUnwrap(
            issueEvent.payload[Schema.EventPayloadKeys.attachmentsJson],
            "Track-1 D1: attachments_json must be present"
        )
        let decoded = try JSONDecoder().decode([AttachmentMeta].self, from: Data(attachJson.utf8))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "Design Spec")
        XCTAssertEqual(decoded[0].mime, "image/png")
        XCTAssertEqual(decoded[0].sizeBytes, 204800)
        XCTAssertEqual(decoded[1].name, "PR Draft")
        XCTAssertNil(decoded[1].mime)
        XCTAssertNil(decoded[1].sizeBytes)
    }

    /// Track-1 D1: when provider signals descriptionTruncated=true, collector emits body_truncated="true".
    /// (BodyCap truncation itself is a provider-level concern — tested in ProdLinearGraphQLProviderTests.)
    func testTick_AppliesBodyCap_TrackD1() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let baseMs: Int64 = 1_700_000_002_000
        // Simulate a snapshot that's already been BodyCap-truncated by the prod
        // provider. The actual capped length is irrelevant for this test — we
        // only verify that descriptionTruncated=true flows to body_truncated payload.
        let cappedBody = "x...content elided\n…[truncated:70000]"
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-D1-cap", title: "Big description", status: "In Progress",
                        project: "Leaf", teamKey: "LEA", updatedAtMs: baseMs,
                        description: cappedBody,
                        descriptionTruncated: true
                    )
                ],
                cursorMs: baseMs
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
                start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
                end: Date(timeIntervalSince1970: TimeInterval(baseMs + 5000) / 1000)
            ))

        let issueEvent = try XCTUnwrap(
            stored.first { $0.payload["event_kind"] == "issue_updated" && $0.payload["issue_key"] == "LEA-D1-cap" }
        )
        XCTAssertEqual(
            issueEvent.payload[Schema.EventPayloadKeys.bodyTruncated], "true",
            "Track-1 D1: descriptionTruncated=true → body_truncated payload key present")
        let body = try XCTUnwrap(issueEvent.payload[Schema.EventPayloadKeys.body])
        XCTAssertTrue(
            body.contains("[truncated:70000]"),
            "Track-1 D1: payload body contains truncation sentinel; got: \(body.suffix(50))")
    }

    /// Empty priorityTransitions → no priority event emitted.
    func testTickDoesNotEmitPriorityEventWhenEmpty() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockLinearGraphQLProvider()
        let cursorMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        await provider.setBatch(
            LinearIssueBatch(
                issues: [
                    LinearIssueSnapshot(
                        issueKey: "LEA-1", title: "Topic", status: "In Progress",
                        project: "", teamKey: "LEA", updatedAtMs: cursorMs
                    )
                ],
                cursorMs: cursorMs
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
        XCTAssertNil(
            stored.first { $0.payload["event_kind"] == "linear_priority_changed" },
            "no priority transitions in batch → no event emitted"
        )
    }

    // MARK: - Phase Track-3 D1 — hot piggy-back emissions

    /// Track-3 D1 — performTick emits one `linear_comment_reaction_added`
    /// event per LinearCommentReactionSnapshot in the batch. Provider already
    /// filters to viewer's own reactions (server-side user.id == viewer.id).
    func testTickEmitsCommentReactionEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)
        let provider = MockLinearGraphQLProvider()
        await provider.setBatch(
            LinearIssueBatch(
                issues: [], cursorMs: nil,
                commentReactions: [
                    LinearCommentReactionSnapshot(
                        id: "rxn-1", commentId: "c-1", issueId: "i-1",
                        issueIdentifier: "LEAF-7", emoji: "thumbsup",
                        createdAtMs: 1_700_000_100_000
                    )
                ]
            ))
        let refresher = LinearTokenRefresher(database: db, clientID: "test-client")
        let collector = LinearCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()
        // Filter out always-emitted workload pulse — plan-tests originally asserted
        // total count but workload pulse fires every tick regardless of inputs.
        try db.readSQL { rawDB in
            let rows = try Row.fetchAll(
                rawDB,
                sql:
                    "SELECT payload_json FROM events WHERE payload_json LIKE '%\"event_kind\":\"linear_comment_reaction_added\"%' ORDER BY id ASC"
            )
            XCTAssertEqual(rows.count, 1, "Expected exactly one reaction event in DB")
            let raw = (rows.first?["payload_json"] as String?) ?? ""
            XCTAssertTrue(raw.contains("\"event_kind\":\"linear_comment_reaction_added\""))
            XCTAssertTrue(raw.contains("\"emoji\":\"thumbsup\""))
            XCTAssertTrue(raw.contains("\"issue_identifier\":\"LEAF-7\""))
        }
    }

    /// Track-3 D1 — performTick emits both `linear_relation_added` and
    /// `linear_relation_removed` events for relationAdditions + relationRemovals
    /// arrays in the batch.
    func testTickEmitsRelationAddedAndRemovedEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)
        let provider = MockLinearGraphQLProvider()
        await provider.setBatch(
            LinearIssueBatch(
                issues: [], cursorMs: nil,
                relationAdditions: [
                    LinearRelationSnapshot(
                        id: "rel-a", fromIssueId: "i-1", fromIssueIdentifier: "LEAF-1",
                        toIssueId: "i-2", toIssueIdentifier: "LEAF-2",
                        relationKind: "blocks", transitionedAtMs: 1_700_000_200_000
                    )
                ],
                relationRemovals: [
                    LinearRelationSnapshot(
                        id: "rel-b", fromIssueId: "i-3", fromIssueIdentifier: "LEAF-3",
                        toIssueId: "i-4", toIssueIdentifier: "LEAF-4",
                        relationKind: "blocked_by", transitionedAtMs: 1_700_000_300_000
                    )
                ]
            ))
        let collector = LinearCollector(
            database: db, provider: provider,
            refresher: LinearTokenRefresher(database: db, clientID: "test-client"),
            intervalSec: 999, backfillWindowDays: 7, logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()
        try db.readSQL { rawDB in
            // Filter to relation events — workload pulse fires every tick regardless.
            let rows = try Row.fetchAll(
                rawDB,
                sql:
                    "SELECT payload_json FROM events WHERE payload_json LIKE '%\"event_kind\":\"linear_relation_%' ORDER BY id ASC"
            )
            XCTAssertEqual(rows.count, 2)
            let texts = rows.compactMap { $0["payload_json"] as String? }
            XCTAssertTrue(texts.contains(where: { $0.contains("\"event_kind\":\"linear_relation_added\"") }))
            XCTAssertTrue(texts.contains(where: { $0.contains("\"event_kind\":\"linear_relation_removed\"") }))
        }
    }

    /// Track-3 D1 — performTick emits both `linear_triage_item_picked_up` and
    /// `linear_triage_item_resolved` events; resolved variant includes
    /// `resolution_kind` payload field derived from WorkflowState.type.
    func testTickEmitsTriagePickedUpAndResolvedEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)
        let provider = MockLinearGraphQLProvider()
        await provider.setBatch(
            LinearIssueBatch(
                issues: [], cursorMs: nil,
                triagePickedUp: [
                    LinearTriageTransitionSnapshot(
                        issueId: "i-1", issueIdentifier: "LEAF-5", teamId: "t-1",
                        toStateName: "Todo", toStateType: "unstarted",
                        transitionedAtMs: 1_700_000_400_000, resolutionKind: nil
                    )
                ],
                triageResolved: [
                    LinearTriageTransitionSnapshot(
                        issueId: "i-2", issueIdentifier: "LEAF-6", teamId: "t-1",
                        toStateName: "Cancelled", toStateType: "canceled",
                        transitionedAtMs: 1_700_000_500_000, resolutionKind: "canceled"
                    )
                ]
            ))
        let collector = LinearCollector(
            database: db, provider: provider,
            refresher: LinearTokenRefresher(database: db, clientID: "test-client"),
            intervalSec: 999, backfillWindowDays: 7, logger: logger,
            userDefaultsSuiteName: makeIsolatedSuiteName()
        )
        _ = await collector.performTick()
        try db.readSQL { rawDB in
            // Filter to triage events — workload pulse fires every tick regardless.
            let rows = try Row.fetchAll(
                rawDB,
                sql:
                    "SELECT payload_json FROM events WHERE payload_json LIKE '%\"event_kind\":\"linear_triage_item_%' ORDER BY id ASC"
            )
            XCTAssertEqual(rows.count, 2)
            let texts = rows.compactMap { $0["payload_json"] as String? }
            XCTAssertTrue(texts.contains(where: { $0.contains("\"event_kind\":\"linear_triage_item_picked_up\"") }))
            XCTAssertTrue(
                texts.contains(where: {
                    $0.contains("\"event_kind\":\"linear_triage_item_resolved\"")
                        && $0.contains("\"resolution_kind\":\"canceled\"")
                }))
        }
    }
}
