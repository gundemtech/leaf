// Track-1 D1 + Track-3 D2 — payload key emission tests (full commit messages,
// PR metadata, inline images, gh_* event_kind rename, hot-tier kinds, reserved
// key guard). Split from GitHubCollectorTests.swift for type_body_length.

import XCTest
import os

@testable import LeafCore

final class GitHubCollectorPayloadKeysTests: XCTestCase {
    private typealias Support = GitHubCollectorTestSupport
    private typealias MockGitHubAPIProvider = GitHubCollectorTestSupport.MockGitHubAPIProvider

    private var tempDir: URL!
    private var dbURL: URL!
    private var logger: Logger { GitHubCollectorTestSupport.logger }

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-github-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func insertFreshIntegration(
        db: Database, login: String = "octocat", expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws {
        try Support.insertFreshIntegration(db: db, login: login, expiresAt: expiresAt)
    }

    // MARK: - Track-1 D1 — payload key emission

    /// Full commit message captured as `body` — NOT truncated to first line.
    /// Track-1 D1 §6 amendment: full message on-device via BodyCap.
    func testTick_FullCommitMessage_NotTruncatedToFirstLine_TrackD1() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_000
        let fullBody = "Subject only\n\nLong body paragraph explaining the context and rationale."
        await provider.setBatch(
            GitHubEventBatch(
                events: [
                    GitHubEventSnapshot(
                        eventID: "push-body-1", eventKind: "gh_commit_pushed",
                        repoFullName: "octocat/leaf",
                        title: "Subject only",
                        number: nil, sha: "abc123", branch: "main",
                        createdAtMs: baseMs,
                        body: fullBody,
                        bodyTruncated: false
                    )
                ],
                cursorMs: baseMs
            ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
                end: Date(timeIntervalSince1970: TimeInterval(baseMs + 1000) / 1000)
            ))
        let event = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_commit_pushed" })
        XCTAssertEqual(
            event.payload[Schema.EventPayloadKeys.body], fullBody,
            "full commit message должен быть в payload.body")
        XCTAssertTrue(
            event.payload[Schema.EventPayloadKeys.body]?.contains("Long body paragraph") == true,
            "body содержит multi-line content")
        XCTAssertNil(
            event.payload[Schema.EventPayloadKeys.bodyTruncated],
            "bodyTruncated absent когда не truncated")
    }

    /// PRMetadata fields всех 6 ключей присутствуют в payload.
    func testTick_PRMetadataPayloadKeys_TrackD1() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_100
        let meta = PRMetadata(
            filesCount: 3, additions: 50, deletions: 10,
            requestedReviewers: ["alice"],
            mentionCount: 1, linkCount: 0
        )
        await provider.setBatch(
            GitHubEventBatch(
                events: [
                    GitHubEventSnapshot(
                        eventID: "pr-meta-1", eventKind: "gh_pr_opened",
                        repoFullName: "octocat/leaf",
                        title: "feat: new feature",
                        number: 10, sha: nil, branch: nil,
                        createdAtMs: baseMs,
                        prMetadata: meta
                    )
                ],
                cursorMs: baseMs
            ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
                end: Date(timeIntervalSince1970: TimeInterval(baseMs + 1000) / 1000)
            ))
        let event = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_pr_opened" })
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.filesCount], "3")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.additions], "50")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.deletions], "10")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.mentionCount], "1")
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.linkCount], "0")
        let reviewersJson = try XCTUnwrap(event.payload[Schema.EventPayloadKeys.requestedReviewersJson])
        XCTAssertTrue(reviewersJson.contains("alice"), "requested_reviewers_json содержит reviewer login")
    }

    /// Inline images parsed from PR body → attachments_json в payload.
    func testTick_InlineImagesParsedFromBody_TrackD1() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_200
        let screenshotAttachment = AttachmentMeta(name: "screenshot.png", mime: "image/png", sizeBytes: nil)
        await provider.setBatch(
            GitHubEventBatch(
                events: [
                    GitHubEventSnapshot(
                        eventID: "pr-attach-1", eventKind: "gh_pr_opened",
                        repoFullName: "octocat/leaf",
                        title: "fix: UI bug",
                        number: 20, sha: nil, branch: nil,
                        createdAtMs: baseMs,
                        attachments: [screenshotAttachment]
                    )
                ],
                cursorMs: baseMs
            ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
                end: Date(timeIntervalSince1970: TimeInterval(baseMs + 1000) / 1000)
            ))
        let event = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_pr_opened" })
        let attachmentsJson = try XCTUnwrap(
            event.payload[Schema.EventPayloadKeys.attachmentsJson],
            "attachments_json должен быть в payload")
        XCTAssertTrue(attachmentsJson.contains("screenshot.png"), "attachments_json содержит filename")
        // JSONEncoder escapes "/" → "\/" in JSON; check for "image" + "png" separately.
        XCTAssertTrue(
            attachmentsJson.contains("image") && attachmentsJson.contains("png"),
            "attachments_json содержит mime type (image/png, possibly JSON-escaped)")
    }

    // MARK: - Track-3 D2 Task 4 — gh_* rename + 7 new hot-tier event_kinds

    /// Snapshot eventKind already prefixed `gh_*` (post-D2 contract — moat parser
    /// emits canonical via GitHubEventKindKey.rawValue) → payload preserves it.
    /// Sanity check that makeEvent doesn't strip / re-map the prefix.
    func testCollectorEmitsGhPrefixedEventKinds() {
        let snapshot = GitHubEventSnapshot(
            eventID: "e1",
            eventKind: GitHubEventKindKey.prOpened.rawValue,
            repoFullName: "owner/foo",
            title: "Hello",
            number: 1,
            sha: nil,
            branch: nil,
            createdAtMs: 1_000,
            body: "PR body text",
            bodyTruncated: false
        )
        let event = GitHubCollector.makeEvent(snapshot: snapshot)
        XCTAssertEqual(event.payload["event_kind"], "gh_pr_opened")
    }

    /// 7 new hot-tier event_kinds (Task 4) — payload preserves event_kind +
    /// new metadata keys flow through via metadata merge (not shadowed).
    func testCollectorEmitsHotTierNewEventKinds() {
        let cases: [(GitHubEventKindKey, [String: String])] = [
            (.issueLocked, [:]),
            (.issueUnlocked, [:]),
            (.workflowManualTriggered, ["workflow_name": "release.yml", "workflow_ref": "refs/heads/main"]),
            (.deploymentCreated, ["deployment_environment": "production"]),
            (.deploymentStatusChanged, ["deployment_environment": "production", "deployment_state": "success"]),
            (.repoCreated, ["repository_visibility": "public"]),
            (.repoForked, ["forkee_full_name": "fork/foo"]),
        ]
        for (kind, metadata) in cases {
            let snapshot = GitHubEventSnapshot(
                eventID: "e",
                eventKind: kind.rawValue,
                repoFullName: "owner/foo",
                title: "",
                number: nil,
                sha: nil,
                branch: nil,
                createdAtMs: 1,
                metadata: metadata.isEmpty ? nil : metadata
            )
            let event = GitHubCollector.makeEvent(snapshot: snapshot)
            XCTAssertEqual(event.payload["event_kind"], kind.rawValue)
            for (k, v) in metadata {
                XCTAssertEqual(event.payload[k], v, "Expected metadata key \(k) preserved for \(kind.rawValue)")
            }
        }
    }

    /// `gh_pr_review_submitted` carries `pr_review_state` discriminator
    /// ("approved" / "changes_requested" / "commented" / "dismissed").
    /// Schema.EventPayloadKeys.prReviewState is the canonical key.
    func testPRReviewSubmittedCarriesStateDiscriminator() {
        let snapshot = GitHubEventSnapshot(
            eventID: "e",
            eventKind: GitHubEventKindKey.prReviewSubmitted.rawValue,
            repoFullName: "owner/foo",
            title: "",
            number: 42,
            sha: nil,
            branch: nil,
            createdAtMs: 1,
            metadata: ["pr_review_state": "approved"]
        )
        let event = GitHubCollector.makeEvent(snapshot: snapshot)
        XCTAssertEqual(event.payload[Schema.EventPayloadKeys.prReviewState], "approved")
    }

    /// Reserved-keys guard предотвращает shadowing: snapshot.metadata с "body"/"additions" ключами
    /// не может перезаписать body/additions из snapshot.body/prMetadata.
    func testTick_ReservedKeysGuard_TrackD1() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertFreshIntegration(db: db)

        let provider = MockGitHubAPIProvider()
        let baseMs: Int64 = 1_700_000_000_300
        let realBody = "real body content — should appear"
        let meta = PRMetadata(
            filesCount: 5, additions: 42, deletions: 1,
            requestedReviewers: [], mentionCount: 0, linkCount: 0
        )
        await provider.setBatch(
            GitHubEventBatch(
                events: [
                    GitHubEventSnapshot(
                        eventID: "guard-1", eventKind: "gh_pr_opened",
                        repoFullName: "octocat/leaf",
                        title: "test",
                        number: 99, sha: nil, branch: nil,
                        createdAtMs: baseMs,
                        // metadata tries to shadow `body` and `additions` keys
                        metadata: ["body": "metadata-shadow", "additions": "999"],
                        body: realBody,
                        bodyTruncated: false,
                        prMetadata: meta
                    )
                ],
                cursorMs: baseMs
            ))

        let refresher = GitHubTokenRefresher(database: db, clientID: "test-client")
        let collector = GitHubCollector(
            database: db, provider: provider, refresher: refresher,
            intervalSec: 999, backfillWindowDays: 7, logger: logger
        )
        _ = await collector.performTick()

        let stored = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1000) / 1000),
                end: Date(timeIntervalSince1970: TimeInterval(baseMs + 1000) / 1000)
            ))
        let event = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "gh_pr_opened" })
        // Real body wins over metadata shadow.
        XCTAssertEqual(
            event.payload[Schema.EventPayloadKeys.body], realBody,
            "real body из snapshot.body должен присутствовать")
        XCTAssertFalse(
            event.payload.values.contains("metadata-shadow"),
            "metadata shadow не должен появляться в payload")
        // Real additions from prMetadata wins over metadata shadow.
        XCTAssertEqual(
            event.payload[Schema.EventPayloadKeys.additions], "42",
            "real additions из prMetadata должны быть в payload")
        XCTAssertFalse(
            event.payload.values.contains("999"),
            "metadata additions shadow не должен перезаписать реальное значение")
    }
}
