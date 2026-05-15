//
//  SupabaseEndpoint.swift
//  LeafCore
//
//  Track 5 / S3 — URL composition + standard header sets for Supabase REST + Edge Function endpoints.
//  Pure value-style — no I/O, easy to unit test.
//

import Foundation

public enum SupabaseEndpoint {

    // MARK: - Auth endpoints

    public static func signupAnonymous(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("auth/v1/signup")
    }

    public static func tokenRefresh(baseURL: URL) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        return components.url!
    }

    // MARK: - Edge Functions

    public static func registerPubkey(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("functions/v1/register_pubkey")
    }

    public static func inviteResolve(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("functions/v1/invite_resolve")
    }

    // MARK: - PostgREST tables

    public static func postInvite(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("rest/v1/invites")
    }

    public static func insertWorkspaceMember(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("rest/v1/workspace_members")
    }

    // MARK: - PostgREST tables — Track 5 / S4 (direct_messages + apns_tokens)

    public static func directMessagesInsert(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("rest/v1/direct_messages")
    }

    public static func directMessagesFetchInbound(
        baseURL: URL,
        workspaceID: String,
        recipientPubkeyHex: String,
        sinceCreatedAtISO: String?,
        limit: Int
    ) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/direct_messages"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "workspace_id", value: "eq.\(workspaceID)"),
            URLQueryItem(name: "recipient_pubkey", value: "eq.\(recipientPubkeyHex)"),
            URLQueryItem(name: "order", value: "created_at.asc"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let since = sinceCreatedAtISO {
            items.append(URLQueryItem(name: "created_at", value: "gt.\(since)"))
        }
        components.queryItems = items
        return components.url!
    }

    public static func directMessagesFetchOutbound(
        baseURL: URL,
        workspaceID: String,
        senderPubkeyHex: String,
        sinceCreatedAtISO: String?,
        limit: Int
    ) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/direct_messages"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "workspace_id", value: "eq.\(workspaceID)"),
            URLQueryItem(name: "sender_pubkey", value: "eq.\(senderPubkeyHex)"),
            URLQueryItem(name: "order", value: "created_at.asc"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let since = sinceCreatedAtISO {
            items.append(URLQueryItem(name: "created_at", value: "gt.\(since)"))
        }
        components.queryItems = items
        return components.url!
    }

    /// I5 fix — Track 5 / S4 Stage 6 review: targeted fetch by message_id for
    /// APNs-wake tickOnce path. Avoids 100-row-window race with bounded fetchInbound.
    public static func directMessagesFetchByID(baseURL: URL, messageID: String) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/direct_messages"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "message_id", value: "eq.\(messageID)"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        return components.url!
    }

    public static func directMessagesPatch(baseURL: URL, messageID: String) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/direct_messages"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "message_id", value: "eq.\(messageID)")]
        return components.url!
    }

    public static func apnsTokensUpsert(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("rest/v1/apns_tokens")
    }

    public static func apnsPush(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("functions/v1/apns_push")
    }

    // MARK: - Edge Functions — Track 5 / S6 (cross-post)

    public static func slackPost(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("functions/v1/slack_post")
    }

    public static func linearCreateIssue(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("functions/v1/linear_create_issue")
    }

    // MARK: - PostgREST tables — Track 5 / S5 (team_events)

    public static func teamEventsInsert(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("rest/v1/team_events")
    }

    /// Fetch inbound team events — workspace-scoped, since-watermark filter
    /// (ms epoch encoded as ISO8601 for PostgREST `gt.<iso>` operator).
    public static func teamEventsFetchInbound(
        baseURL: URL,
        workspaceID: String,
        sinceCreatedAtISO: String?,
        limit: Int
    ) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/team_events"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "workspace_id", value: "eq.\(workspaceID)"),
            URLQueryItem(name: "order", value: "created_at.asc"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let since = sinceCreatedAtISO {
            items.append(URLQueryItem(name: "created_at", value: "gt.\(since)"))
        }
        components.queryItems = items
        return components.url!
    }

    // MARK: - Header builders

    public static func anonHeaders(anonKey: String) -> [String: String] {
        [
            "apikey": anonKey,
            "Content-Type": "application/json",
        ]
    }

    public static func authenticatedHeaders(anonKey: String, accessToken: String) -> [String: String] {
        [
            "apikey": anonKey,
            "Authorization": "Bearer \(accessToken)",
            "Content-Type": "application/json",
        ]
    }

    public static func postgrestInsertHeaders(anonKey: String, accessToken: String) -> [String: String] {
        [
            "apikey": anonKey,
            "Authorization": "Bearer \(accessToken)",
            "Content-Type": "application/json",
            "Prefer": "return=representation",
        ]
    }

    /// Track 5 / S5 — PostgREST INSERT with merge-duplicates resolution.
    /// 409 conflicts are silently transformed by PostgREST into 200/201
    /// echoing the existing row, so retry storms after transient network
    /// failures don't create duplicate rows. Used by sendTeamEvent where
    /// the broadcast service may re-attempt the same deterministic
    /// (workspace_id, event_id) tuple after a network blip.
    public static func postgrestInsertHeadersIgnoreDuplicates(anonKey: String, accessToken: String) -> [String: String] {
        [
            "apikey": anonKey,
            "Authorization": "Bearer \(accessToken)",
            "Content-Type": "application/json",
            "Prefer": "return=representation,resolution=merge-duplicates",
        ]
    }

    /// Track 5 / S4 — PostgREST UPSERT via `Prefer: resolution=merge-duplicates`.
    /// Used by `apns_tokens` UPSERT path (token rotation reuses PK).
    public static func postgrestUpsertHeaders(anonKey: String, accessToken: String) -> [String: String] {
        [
            "apikey": anonKey,
            "Authorization": "Bearer \(accessToken)",
            "Content-Type": "application/json",
            "Prefer": "resolution=merge-duplicates, return=minimal",
        ]
    }

    /// Track 5 / S4 — PATCH via PostgREST. Caller URL composer carries the
    /// `?message_id=eq.<uuid>` query filter; this just adds the standard headers.
    public static func postgrestPatchHeaders(anonKey: String, accessToken: String) -> [String: String] {
        [
            "apikey": anonKey,
            "Authorization": "Bearer \(accessToken)",
            "Content-Type": "application/json",
            "Prefer": "return=minimal",
        ]
    }
}
