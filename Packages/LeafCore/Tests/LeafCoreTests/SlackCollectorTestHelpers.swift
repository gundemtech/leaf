// Shared mock provider + fixture helpers for SlackCollector*Tests files.
// Split from SlackCollectorTests.swift for type_body_length / file_length.

import XCTest
import os

@testable import LeafCore

enum SlackCollectorTestSupport {
    static let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "slack-collector")

    /// Captures `since` / `userID` calls для assertion'ов; injectable
    /// `nextResult: SlackTickResult` (default — `.empty`).
    /// Phase 4.7.B-9 — также injectable presence + counter для tick'ов.
    /// Phase 4.7.B-10 — также injectable DND + counter для tick'ов.
    /// Phase 4.7.B-11 — также injectable mentions + counter для tick'ов.
    /// Phase 4.7.B-12 — также injectable file upload summary + counter.
    actor MockSlackAPIProvider: SlackAPIProvider {
        private(set) var sinceCalls: [Int64?] = []
        private(set) var userIDCalls: [String] = []
        private(set) var presenceCalls: Int = 0
        private(set) var dndCalls: Int = 0
        private(set) var mentionCalls: Int = 0
        private(set) var mentionSinceCalls: [Int64] = []
        private(set) var filesCalls: Int = 0
        private(set) var filesSinceCalls: [Int64] = []
        // Track-1 D1 — thread reply tracking
        private(set) var threadReplyCalls: [(channelID: String, threadTs: String, oldest: String?)] = []
        private var nextResult: SlackTickResult = .empty
        private var nextPresence: SlackPresenceState = .unknown
        private var nextDND: SlackDNDState = .empty
        private var nextMentions: [SlackMentionChannelCount] = []
        private var nextFiles: SlackFileUploadSummary = .empty(periodStartMs: 0, periodEndMs: 0)
        private var presenceShouldThrow: Bool = false
        private var dndShouldThrow: Bool = false
        private var mentionsShouldThrow: Bool = false
        private var filesShouldThrow: Bool = false
        // Track-1 D1 — per-thread reply config
        private var nextThreadReplyBatch: SlackThreadReplyBatch = .empty
        // Maps threadTs → throw RateLimitError when called (for 429 test)
        private var threadReplyThrowOn: Set<String> = []

        func fetchTick(
            accessToken: String,
            userID: String,
            since: Int64?,
            now: Date
        ) async throws -> SlackTickResult {
            sinceCalls.append(since)
            userIDCalls.append(userID)
            return nextResult
        }

        func fetchPresence(
            accessToken: String,
            userID: String
        ) async throws -> SlackPresenceState {
            presenceCalls += 1
            if presenceShouldThrow {
                struct DummyError: Error {}
                throw DummyError()
            }
            return nextPresence
        }

        func fetchDND(
            accessToken: String,
            userID: String
        ) async throws -> SlackDNDState {
            dndCalls += 1
            if dndShouldThrow {
                struct DummyError: Error {}
                throw DummyError()
            }
            return nextDND
        }

        func fetchMentionsReceived(
            accessToken: String,
            userID: String,
            since: Int64
        ) async throws -> [SlackMentionChannelCount] {
            mentionCalls += 1
            mentionSinceCalls.append(since)
            if mentionsShouldThrow {
                struct DummyError: Error {}
                throw DummyError()
            }
            return nextMentions
        }

        func fetchFilesUploaded(
            accessToken: String,
            userID: String,
            since: Int64
        ) async throws -> SlackFileUploadSummary {
            filesCalls += 1
            filesSinceCalls.append(since)
            if filesShouldThrow {
                struct DummyError: Error {}
                throw DummyError()
            }
            return nextFiles
        }

        func fetchThreadReplies(
            accessToken: String,
            channelID: String,
            threadTs: String,
            ownerUserID: String,
            oldest: String?
        ) async throws -> SlackThreadReplyBatch {
            threadReplyCalls.append((channelID: channelID, threadTs: threadTs, oldest: oldest))
            if threadReplyThrowOn.contains(threadTs) {
                throw RateLimitError.retryAfter(30)
            }
            return nextThreadReplyBatch
        }

        // Phase Track-3 D3 — warm/cold protocol stubs. Existing SlackCollector tests
        // never call these (collector wiring lands in Tasks 12 / 14); returning
        // `.empty` keeps SlackAPIProvider conformance compiling.
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
            .empty
        }

        func setResult(_ result: SlackTickResult) { nextResult = result }
        func setPresence(_ presence: SlackPresenceState) { nextPresence = presence }
        func setPresenceShouldThrow(_ shouldThrow: Bool) { presenceShouldThrow = shouldThrow }
        func setDND(_ dnd: SlackDNDState) { nextDND = dnd }
        func setDNDShouldThrow(_ shouldThrow: Bool) { dndShouldThrow = shouldThrow }
        func setMentions(_ mentions: [SlackMentionChannelCount]) { nextMentions = mentions }
        func setMentionsShouldThrow(_ shouldThrow: Bool) { mentionsShouldThrow = shouldThrow }
        func setFiles(_ files: SlackFileUploadSummary) { nextFiles = files }
        func setFilesShouldThrow(_ shouldThrow: Bool) { filesShouldThrow = shouldThrow }
        // Track-1 D1 thread reply helpers
        func setThreadReplyBatch(_ batch: SlackThreadReplyBatch) { nextThreadReplyBatch = batch }
        func setThreadReplyThrowOn(_ threadTs: String) { threadReplyThrowOn.insert(threadTs) }
        func threadReplyCallHistory() -> [(channelID: String, threadTs: String, oldest: String?)] { threadReplyCalls }
        func sinceHistory() -> [Int64?] { sinceCalls }
        func userIDHistory() -> [String] { userIDCalls }
        func presenceCallCount() -> Int { presenceCalls }
        func dndCallCount() -> Int { dndCalls }
        func mentionCallCount() -> Int { mentionCalls }
        func mentionSinceHistory() -> [Int64] { mentionSinceCalls }
        func filesCallCount() -> Int { filesCalls }
        func filesSinceHistory() -> [Int64] { filesSinceCalls }
    }

    static func makeDB(at dbURL: URL) throws -> Database {
        try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    static func insertFreshIntegration(
        db: Database,
        workspaceID: String = "T123:U456",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws {
        let record = IntegrationRecord(
            provider: .slack,
            workspaceID: workspaceID,
            workspaceName: "Acme",
            accessToken: "xoxe.xoxp-test",
            refreshToken: "xoxe-1-test",
            expiresAt: expiresAt,
            scope: SlackOAuthEndpoints.userScopes,
            connectedAt: Date(),
            updatedAt: Date()
        )
        try db.upsertIntegration(record)
    }

    static func makeCollector(
        db: Database,
        provider: any SlackAPIProvider,
        intervalSec: TimeInterval = 999,
        maxThreadsPerTick: Int = Int.max
    ) -> SlackCollector {
        let refresher = SlackTokenRefresher(database: db, clientID: "test-client")
        return SlackCollector(
            database: db,
            provider: provider,
            refresher: refresher,
            intervalSec: intervalSec,
            backfillWindowDays: 7,
            maxThreadsPerTick: maxThreadsPerTick,
            logger: logger
        )
    }

    static func huddleEventInDB(state: String, atMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": "slack_huddle_state_change",
                "state": state,
            ]
        )
    }
}
