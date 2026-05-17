//
//  SlackColdCollectorTestHelpers.swift
//  LeafCoreTests
//
//  Shared SpyProvider + scope fakes + fixture helpers used by
//  SlackColdCollector*Tests files. Split from SlackColdCollectorTests.swift
//  to clear type_body_length / file_length violations.
//

import XCTest
import os

import class GRDB.Row

@testable import LeafCore

// swiftlint:disable force_unwrapping
// Reason: test fixtures rely on force-unwrap for setup convenience —
// URL literals, HTTPURLResponse construction, decoded JSON, post-`try`
// DB reads where nil ⇒ broken test, not production semantic.

enum SlackColdCollectorTestSupport {
    static let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "slack-cold")

    struct AlwaysGrantedScopes: SlackScopesChecking {
        func has(_ scope: String) async -> Bool { true }
    }

    struct ScopesMissing: SlackScopesChecking {
        let missing: Set<String>
        init(_ missing: Set<String>) { self.missing = missing }
        func has(_ scope: String) async -> Bool { !missing.contains(scope) }
    }

    /// Spy SlackAPIProvider — only `fetchColdState` is exercised. Other
    /// protocol methods are stubbed.
    actor SpyProvider: SlackAPIProvider {
        var nextBatch: SlackColdBatch = .empty
        var fetchColdStateCallCount = 0
        var lastSeenTopChannels: SlackMemberChannelsTopList?
        var shouldThrow: Bool = false

        func setBatch(_ b: SlackColdBatch) { nextBatch = b }
        func setShouldThrow(_ v: Bool) { shouldThrow = v }

        struct StubError: Error {}

        func fetchTick(accessToken: String, userID: String, since: Int64?, now: Date) async throws -> SlackTickResult {
            .empty
        }
        func fetchPresence(accessToken: String, userID: String) async throws -> SlackPresenceState { .unknown }
        func fetchDND(accessToken: String, userID: String) async throws -> SlackDNDState { .empty }
        func fetchMentionsReceived(
            accessToken: String, userID: String, since: Int64
        ) async throws -> [SlackMentionChannelCount] { [] }
        func fetchFilesUploaded(
            accessToken: String, userID: String, since: Int64
        ) async throws -> SlackFileUploadSummary { .empty(periodStartMs: 0, periodEndMs: 0) }
        func fetchThreadReplies(
            accessToken: String, channelID: String, threadTs: String, ownerUserID: String, oldest: String?
        ) async throws -> SlackThreadReplyBatch { .empty }

        func fetchWarmState(
            accessToken: String,
            userID: String,
            scopes: SlackScopesChecking,
            priors: SlackWarmStatePriorSnapshots,
            since: Int64?,
            now: Int64
        ) async throws -> SlackWarmBatch {
            .empty
        }

        func fetchColdState(
            accessToken: String,
            userID: String,
            scopes: SlackScopesChecking,
            topChannels: SlackMemberChannelsTopList,
            now: Int64
        ) async throws -> SlackColdBatch {
            fetchColdStateCallCount += 1
            lastSeenTopChannels = topChannels
            if shouldThrow { throw StubError() }
            return nextBatch
        }
    }

    static func insertSlackIntegration(_ db: Database, teamID: String = "T1", userID: String = "U1") throws {
        try db.upsertIntegration(
            IntegrationRecord(
                provider: .slack,
                workspaceID: "\(teamID):\(userID)",
                workspaceName: "Acme",
                accessToken: "tok",
                refreshToken: nil,
                expiresAt: nil,
                scope: "canvases:read,emoji:read,usergroups:read,channels:read",
                connectedAt: Date(),
                updatedAt: Date()
            ))
    }

    static func makeCollector(
        _ db: Database,
        _ provider: SpyProvider,
        scopes: any SlackScopesChecking = AlwaysGrantedScopes(),
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 100) }
    ) -> SlackColdCollector {
        SlackColdCollector(
            database: db,
            provider: provider,
            tokenRefresher: SlackTokenRefresher(database: db, clientID: "cid"),
            scopes: scopes,
            workspaceIDProvider: { "T1" },
            userIDProvider: { "U1" },
            clock: clock,
            logger: logger
        )
    }

    static func seedPriorSnapshot(_ db: Database, kind: String, json: String) throws {
        try db.writeSQL { raw in
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(
                    provider: "slack",
                    snapshotKind: kind,
                    snapshotJSON: json,
                    capturedAtMs: 0
                ), in: raw)
        }
    }

    static func eventCount(_ db: Database, eventKind: String) throws -> Int {
        var count = 0
        try db.readSQL { raw in
            let rows = try Row.fetchAll(
                raw,
                sql: """
                    SELECT payload_json FROM events
                    WHERE json_extract(payload_json, '$.event_kind') = ?
                    """, arguments: [eventKind])
            count = rows.count
        }
        return count
    }

    static func eventPayload(_ db: Database, eventKind: String) throws -> [String: Any]? {
        var payload: [String: Any]?
        try db.readSQL { raw in
            let rows = try Row.fetchAll(
                raw,
                sql: """
                    SELECT payload_json FROM events
                    WHERE json_extract(payload_json, '$.event_kind') = ?
                    """, arguments: [eventKind])
            guard let row = rows.first, let json: String = row["payload_json"] else { return }
            let data = Data(json.utf8)
            payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return payload
    }

    static func seedTopChannels(_ db: Database, _ channels: [SlackMemberChannel]) throws {
        let list = SlackMemberChannelsTopList(channels: channels)
        let data = try JSONEncoder().encode(list)
        let json = String(data: data, encoding: .utf8)!
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackMemberChannels, json: json)
    }
}
// swiftlint:enable force_unwrapping
