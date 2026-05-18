//
//  AttachmentMetadataResolver.swift
//  LeafCore
//
//  Track 5 / S7 C.8 + C.9 — Actor with TTL cache + local events table lookup
//  (C.8) and collector fetch fallback (C.9).
//
//  Resolution flow per spec §7.3:
//    1. Cache lookup (TTL 300s for hits; 60s for nil results).
//    2. Local `events` table via json_extract on payload_json.
//    3. Collector fetch fallback (C.9); returns nil if collectorsRegistry == nil.
//    4. Cache result; return.
//
//  Local events table payload is a flat [String: String] JSON object (all values
//  are strings). Nested keys from the spec (user.login, state.name, etc.) do not
//  exist in this table — only collector fetch (step 3) can return rich metadata.
//  The local lookup is best-effort: constructs what it can from flat fields.
//

import Foundation
import GRDB
import os

// MARK: - AttachmentMetadataResolver

/// Actor that resolves display metadata for a DM attachment link.
///
/// Cache behaviour:
/// - Successful hits (non-nil): cached for `ttl` seconds (default 300s).
/// - Failed lookups (nil): cached for `nilTTL` seconds (default 60s) to avoid
///   retry storms when a provider is down or a ref is genuinely unresolvable.
///
/// Resolution order: cache → local events table → collector fetch fallback.
public actor AttachmentMetadataResolver {

    // MARK: - Cache types

    private struct CacheKey: Hashable {
        let provider: AttachmentProvider
        let externalRef: String
    }

    private struct CacheEntry {
        let metadata: AttachmentMetadata?
        let storedAt: Date
    }

    // MARK: - State

    private let database: Database
    private let collectorsRegistry: CollectorsRegistry?
    private var cache: [CacheKey: CacheEntry] = [:]
    private let ttl: TimeInterval = 300       // 5 minutes for successful hits
    private let nilTTL: TimeInterval = 60     // 60s for nil results
    private let now: @Sendable () -> Date

    private let logger = Logger(subsystem: "tech.gundem.leaf", category: "attachment-resolver")

    // MARK: - Init

    public init(
        database: Database,
        collectorsRegistry: CollectorsRegistry? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.collectorsRegistry = collectorsRegistry
        self.now = now
    }

    // MARK: - Public API

    /// Resolve display metadata for the given attachment.
    ///
    /// Returns nil if all resolution steps fail (local miss + collector miss / no registry).
    /// Nil results are cached for 60s to limit retry frequency.
    public func resolve(provider: AttachmentProvider, externalRef: String) async -> AttachmentMetadata? {
        let key = CacheKey(provider: provider, externalRef: externalRef)

        // Step 1: Cache lookup.
        if let entry = cache[key] {
            let age = now().timeIntervalSince(entry.storedAt)
            let effective = entry.metadata == nil ? nilTTL : ttl
            if age < effective {
                return entry.metadata
            }
            // Expired — fall through to re-resolve.
        }

        // Step 2: Local events table lookup.
        if let local = lookupLocal(provider: provider, externalRef: externalRef) {
            cache[key] = CacheEntry(metadata: local, storedAt: now())
            return local
        }

        // Step 3: Collector fetch fallback (C.9).
        let fetched = await fetchFromCollector(provider: provider, externalRef: externalRef)
        cache[key] = CacheEntry(metadata: fetched, storedAt: now())
        return fetched
    }

    // MARK: - Local lookup (C.8)

    /// Searches the local `events` table for a matching event using json_extract.
    ///
    /// The events table stores flat [String: String] payloads. Supported lookups:
    /// - GitHub: event_kind GLOB 'gh*' + number field matches externalRef.
    ///           (matches both production prefix `gh_pr_*` / `gh_commit_*` and the
    ///            legacy `github_*` family found in older fixtures.)
    /// - Linear: event_kind GLOB 'linear*' + issue_key field matches externalRef.
    /// - Slack:  event_kind GLOB 'slack*' + channel_id + thread_ts match
    ///           the "<channel>/<ts>" externalRef format.
    ///
    /// S7 Stage 6 fix B-C1: each lookup carries an `event_kind GLOB 'prefix*'`
    /// predicate as the leading WHERE term. M011's expression index
    /// `idx_events_event_kind_ts` is on `(json_extract($.event_kind), ts)`.
    /// SQLite converts GLOB-prefix to a BINARY range scan that can seek into
    /// the expression index — LIKE would not, because default LIKE is
    /// case-insensitive while expression indexes default to BINARY collation
    /// (the two collations don't match, so the planner can't safely
    /// substitute a range). GLOB is always case-sensitive BINARY, which
    /// matches the index collation. The follow-on `$.source` + identifier
    /// checks become residual filters on the already-narrowed set.
    ///
    /// Returns nil on any DB error or if required fields are missing.
    private func lookupLocal(provider: AttachmentProvider, externalRef: String) -> AttachmentMetadata? {
        do {
            return try database.readSQL { db -> AttachmentMetadata? in
                let row: Row?
                switch provider {
                case .github:
                    // externalRef format: "owner/repo#<number>" or plain "<number>"
                    // Extract number from the ref.
                    let number = Self.extractGitHubNumber(from: externalRef)
                    guard let number else { return nil }
                    // events table has no event_kind column — it lives inside payload_json.
                    // event_kind GLOB 'gh*' is the index-using leading predicate;
                    // source + number narrow further.
                    let sql = """
                        SELECT payload_json FROM events
                        WHERE json_extract(payload_json, '$.event_kind') GLOB 'gh*'
                          AND json_extract(payload_json, '$.source') = 'github'
                          AND json_extract(payload_json, '$.number') = ?
                          AND json_extract(payload_json, '$.number') != ''
                        ORDER BY ts DESC LIMIT 1
                    """
                    row = try Row.fetchOne(db, sql: sql, arguments: [number])
                case .linear:
                    // externalRef: "LEAF-128" style identifier matching issue_key field.
                    let sql = """
                        SELECT payload_json FROM events
                        WHERE json_extract(payload_json, '$.event_kind') GLOB 'linear*'
                          AND json_extract(payload_json, '$.source') = 'linear'
                          AND json_extract(payload_json, '$.issue_key') = ?
                        ORDER BY ts DESC LIMIT 1
                    """
                    row = try Row.fetchOne(db, sql: sql, arguments: [externalRef])
                case .slack:
                    // externalRef: "<channel_id>/<ts>"
                    let parts = externalRef.split(separator: "/", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    let channelID = String(parts[0])
                    let threadTs = String(parts[1])
                    let sql = """
                        SELECT payload_json FROM events
                        WHERE json_extract(payload_json, '$.event_kind') GLOB 'slack*'
                          AND json_extract(payload_json, '$.source') = 'slack'
                          AND json_extract(payload_json, '$.channel_id') = ?
                          AND json_extract(payload_json, '$.thread_ts') = ?
                        ORDER BY ts DESC LIMIT 1
                    """
                    row = try Row.fetchOne(db, sql: sql, arguments: [channelID, threadTs])
                }
                guard let row,
                      let payloadJSON: String = row["payload_json"] else { return nil }
                return Self.parseMetadataFromFlatPayload(provider: provider, payloadJSON: payloadJSON)
            }
        } catch {
            logger.debug("local lookup error for \(provider.rawValue, privacy: .public)/\(externalRef, privacy: .private): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Parse metadata from the flat [String: String] payload stored in events table.
    ///
    /// All JSON values at the top level are strings (not nested objects). Fields
    /// like title, status, repo, number, issue_key, channel_id, thread_ts, body
    /// are top-level string keys.
    private nonisolated static func parseMetadataFromFlatPayload(
        provider: AttachmentProvider,
        payloadJSON: String
    ) -> AttachmentMetadata? {
        guard let data = payloadJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        switch provider {
        case .github:
            // Events store: title, number, repo, event_kind, sha, branch, source
            guard let title = json["title"], !title.isEmpty,
                  let number = json["number"], !number.isEmpty,
                  let repo = json["repo"], !repo.isEmpty else { return nil }
            let eventKind = json["event_kind"] ?? ""
            let isMerged = eventKind.contains("merged")
            let isClosed = eventKind.contains("closed")
            let state: String
            let colorKey: StatusColorKey
            if isMerged {
                state = "merged"
                colorKey = .merged
            } else if isClosed {
                state = "closed"
                colorKey = .closed
            } else {
                state = "open"
                colorKey = .open
            }
            // Construct GitHub URL from repo + number.
            guard let url = URL(string: "https://github.com/\(repo)/pull/\(number)") else { return nil }
            return AttachmentMetadata(
                title: title,
                statusLabel: state,
                statusColorKey: colorKey,
                authorDisplayName: "—",
                createdAtMs: 0,
                externalURL: url
            )

        case .linear:
            // Events store: title, issue_key, status, team_key, project, source
            guard let title = json["title"], !title.isEmpty,
                  let issueKey = json["issue_key"], !issueKey.isEmpty else { return nil }
            let status = json["status"] ?? "—"
            let colorKey = Self.linearStatusColor(status)
            // Linear issue URL requires workspace slug which isn't in flat payload.
            // Use linear.app search as best-effort URL.
            guard let url = URL(string: "https://linear.app/issue/\(issueKey)") else { return nil }
            return AttachmentMetadata(
                title: title,
                statusLabel: status,
                statusColorKey: colorKey,
                authorDisplayName: "—",
                createdAtMs: 0,
                externalURL: url
            )

        case .slack:
            // Events store: body (thread content), channel_id, thread_ts, source
            let text = json["body"] ?? json["text"] ?? "—"
            let channelID = json["channel_id"] ?? "—"
            let threadTs = json["thread_ts"] ?? "—"
            let title = String(text.prefix(80))
            // Slack message URL requires workspace domain. Use a resolvable deep link.
            guard let url = URL(string: "https://slack.com/archives/\(channelID)/p\(threadTs.replacingOccurrences(of: ".", with: ""))") else { return nil }
            return AttachmentMetadata(
                title: title,
                statusLabel: "#\(channelID)",
                statusColorKey: .neutral,
                authorDisplayName: "—",
                createdAtMs: 0,
                externalURL: url
            )
        }
    }

    // MARK: - Parsing helpers

    private nonisolated static func extractGitHubNumber(from externalRef: String) -> String? {
        // Supports formats: "42", "owner/repo#42", "PR #42", "#42"
        // Try to extract the trailing digits after optional '#'.
        if let hashIdx = externalRef.lastIndex(of: "#") {
            let after = String(externalRef[externalRef.index(after: hashIdx)...])
                .trimmingCharacters(in: .whitespaces)
            if !after.isEmpty && after.allSatisfy(\.isNumber) { return after }
        }
        // Plain number string.
        let trimmed = externalRef.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber) { return trimmed }
        return nil
    }

    private nonisolated static func linearStatusColor(_ status: String) -> StatusColorKey {
        let lower = status.lowercased()
        if lower.contains("in progress") || lower.contains("started") || lower.contains("doing") {
            return .inProgress
        }
        if lower.contains("done") || lower.contains("completed") || lower.contains("closed") {
            return .completed
        }
        if lower.contains("cancelled") || lower.contains("canceled") {
            return .closed
        }
        if lower.contains("blocked") { return .blocked }
        return .open
    }

    // MARK: - Collector fetch fallback (C.9)

    private func fetchFromCollector(provider: AttachmentProvider, externalRef: String) async -> AttachmentMetadata? {
        guard let registry = collectorsRegistry else { return nil }
        switch provider {
        case .github:
            return await registry.gitHubProvider?.resolveAttachment(externalRef: externalRef)
        case .linear:
            return await registry.linearProvider?.resolveAttachment(externalRef: externalRef)
        case .slack:
            return await registry.slackProvider?.resolveAttachment(externalRef: externalRef)
        }
    }
}

// MARK: - CollectorsRegistry

/// Pluggable per-provider attachment resolvers.
///
/// Production wiring in Phase H supplies live providers; tests inject mocks.
/// nil entries → skip fetch for that provider (no fallback).
public struct CollectorsRegistry: Sendable {
    public let gitHubProvider: (any GitHubAttachmentProvider)?
    public let linearProvider: (any LinearAttachmentProvider)?
    public let slackProvider: (any SlackAttachmentProvider)?

    public init(
        gitHubProvider: (any GitHubAttachmentProvider)? = nil,
        linearProvider: (any LinearAttachmentProvider)? = nil,
        slackProvider: (any SlackAttachmentProvider)? = nil
    ) {
        self.gitHubProvider = gitHubProvider
        self.linearProvider = linearProvider
        self.slackProvider = slackProvider
    }
}

// MARK: - Provider protocols (C.9)

/// Protocol for resolving GitHub attachment metadata (e.g. PR details).
/// Phase H wires real GitHubAPIProvider; tests inject mocks.
public protocol GitHubAttachmentProvider: Sendable {
    /// Resolve metadata for a GitHub PR/issue reference.
    /// - Parameter externalRef: e.g. "owner/repo#42" or "42"
    func resolveAttachment(externalRef: String) async -> AttachmentMetadata?
}

/// Protocol for resolving Linear attachment metadata (e.g. issue details).
/// Phase H wires real LinearGraphQLProvider; tests inject mocks.
public protocol LinearAttachmentProvider: Sendable {
    /// Resolve metadata for a Linear issue reference.
    /// - Parameter externalRef: e.g. "LEAF-128"
    func resolveAttachment(externalRef: String) async -> AttachmentMetadata?
}

/// Protocol for resolving Slack attachment metadata (e.g. message context).
/// Phase H wires real Slack API client; tests inject mocks.
public protocol SlackAttachmentProvider: Sendable {
    /// Resolve metadata for a Slack message reference.
    /// - Parameter externalRef: e.g. "<channel_id>/<ts>"
    func resolveAttachment(externalRef: String) async -> AttachmentMetadata?
}
