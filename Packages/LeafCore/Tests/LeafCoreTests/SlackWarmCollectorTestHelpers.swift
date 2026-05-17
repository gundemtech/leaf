//
//  SlackWarmCollectorTestHelpers.swift
//  LeafCoreTests
//
//  Shared SpyProvider + scope fakes + fixture helpers for SlackWarmCollector*Tests
//  files. Split from SlackWarmCollectorTests.swift for type_body_length.
//

import XCTest
import os

import class GRDB.Row

@testable import LeafCore

enum SlackWarmCollectorTestSupport {
    static let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "slack-warm")

    struct AlwaysGrantedScopes: SlackScopesChecking {
        func has(_ scope: String) async -> Bool { true }
    }

    struct ScopesMissing: SlackScopesChecking {
        let missing: Set<String>
        init(_ missing: Set<String>) { self.missing = missing }
        func has(_ scope: String) async -> Bool { !missing.contains(scope) }
    }

    /// Spy SlackAPIProvider — only `fetchWarmState` is exercised by the warm
    /// collector; the other protocol methods are stubbed with `.empty`-like
    /// returns. `nextBatch` is the warm batch the next tick will see; the
    /// spy also records the inbound prior-snapshot arguments so tests can
    /// assert top-10 capping behaviour.
    actor SpyProvider: SlackAPIProvider {
        var nextBatch: SlackWarmBatch = .empty
        var fetchWarmStateCallCount = 0
        var lastSeenPriorMemberChannels: SlackMemberChannelsTopList?
        var lastSeenPriorPins: [SlackChannelPinsSnapshot] = []
        var lastSeenSince: Int64?
        var shouldThrow: Bool = false

        func setBatch(_ b: SlackWarmBatch) { nextBatch = b }
        func setShouldThrow(_ v: Bool) { shouldThrow = v }

        struct StubError: Error {}

        // Hot-tier no-ops.
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

        // Warm.
        func fetchWarmState(
            accessToken: String,
            userID: String,
            scopes: SlackScopesChecking,
            priors: SlackWarmStatePriorSnapshots,
            since: Int64?,
            now: Int64
        ) async throws -> SlackWarmBatch {
            fetchWarmStateCallCount += 1
            lastSeenPriorMemberChannels = priors.memberChannels
            lastSeenPriorPins = priors.pinsPerChannel
            lastSeenSince = since
            if shouldThrow { throw StubError() }
            return nextBatch
        }

        // Cold — no-op.
        func fetchColdState(
            accessToken: String, userID: String, scopes: SlackScopesChecking, topChannels: SlackMemberChannelsTopList,
            now: Int64
        ) async throws -> SlackColdBatch { .empty }
    }

    static func insertSlackIntegration(_ db: Database, teamID: String = "T1", userID: String = "U1") throws {
        try db.upsertIntegration(
            IntegrationRecord(
                provider: .slack,
                workspaceID: "\(teamID):\(userID)",
                workspaceName: "Acme",
                accessToken: "tok",
                refreshToken: nil,
                expiresAt: nil,  // long-lived (no rotation) — refresher no-ops
                scope: "channels:read,pins:read,bookmarks:read,reminders:read,reactions:read,stars:read",
                connectedAt: Date(),
                updatedAt: Date()
            ))
    }

    static func makeCollector(
        _ db: Database,
        _ provider: SpyProvider,
        scopes: any SlackScopesChecking = AlwaysGrantedScopes(),
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 100) }
    ) -> SlackWarmCollector {
        SlackWarmCollector(
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
}
