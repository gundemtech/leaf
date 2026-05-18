//
//  RealtimePhoenixMessage.swift
//  LeafCore
//
//  Track 5 / S7 — Phoenix Channels wire-frame helpers used by RealtimeWebSocketDriver.
//
//  Wire format (Phoenix v2 over Supabase Realtime, JSON encoding):
//
//      { "topic": "<topic>",
//        "event": "<event>",
//        "payload": { ... },
//        "ref":   "<monotonic-int-as-string>" }
//
//  Out-bound frames we send:
//   • phx_join — initial channel join carrying postgres_changes config + access_token
//   • phx_leave — graceful detach
//   • heartbeat — keepalive (D.5 — out of scope here, included as a builder)
//
//  In-bound frames we parse:
//   • phx_reply — ack/nack for our outbound refs (status: ok | error)
//   • postgres_changes — INSERT/UPDATE/DELETE events
//   • phx_close — server-side channel close
//   • phx_error — server-side error event
//
//  All builders return `[String: Any]` for `JSONSerialization`, matching the
//  rest of the SupabaseClient codebase (which already mixes Codable for typed
//  bodies + JSONSerialization for dict bodies).
//

import Foundation

/// Phoenix channel topic prefix for Supabase Realtime channels.
public enum RealtimeTopic {
    /// Build the workspace-scoped Phoenix topic. Format: `realtime:leaf-workspace-<wid>`.
    /// The `realtime:` prefix is required by the Supabase Realtime server.
    public static func forWorkspace(_ workspaceID: String) -> String {
        "realtime:leaf-workspace-\(workspaceID)"
    }
}

/// Phoenix message envelope — used internally for typed parsing.
/// Not Sendable: `payload` carries arbitrary JSON via [String: Any]. Consumed
/// synchronously inside the driver actor; never crosses isolation boundaries.
struct RealtimePhoenixMessage {
    let topic: String
    let event: String
    let payload: [String: Any]
    let ref: String?

    /// Parse from a JSON string received over WebSocket Text frame.
    /// Returns nil on malformed JSON / non-object root / missing required fields.
    static func parse(_ json: String) -> RealtimePhoenixMessage? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return nil }
        let topic = (dict["topic"] as? String) ?? ""
        let event = (dict["event"] as? String) ?? ""
        let payload = (dict["payload"] as? [String: Any]) ?? [:]
        let ref = dict["ref"] as? String
        return RealtimePhoenixMessage(topic: topic, event: event, payload: payload, ref: ref)
    }
}

/// Builders for out-bound Phoenix frames. Pure functions — no actor state.
enum RealtimePhoenixFrame {

    /// Build phx_join frame payload for workspace channel:
    ///   • broadcast.self = false (we don't echo our own inserts)
    ///   • presence.key = "" (no presence usage in S7)
    ///   • postgres_changes: 3 subscriptions (INSERT team_events, INSERT direct_messages, UPDATE direct_messages)
    ///   • access_token: JWT for Realtime auth (sent INSIDE payload, not as WS header)
    static func phxJoin(workspaceID: String, accessToken: String, ref: String) throws -> String {
        let topic = RealtimeTopic.forWorkspace(workspaceID)
        let filter = "workspace_id=eq.\(workspaceID)"
        let changes: [[String: Any]] = [
            ["event": "INSERT", "schema": "public", "table": "team_events", "filter": filter],
            ["event": "INSERT", "schema": "public", "table": "direct_messages", "filter": filter],
            ["event": "UPDATE", "schema": "public", "table": "direct_messages", "filter": filter],
        ]
        let payload: [String: Any] = [
            "config": [
                "broadcast": ["self": false],
                "presence": ["key": ""],
                "postgres_changes": changes,
            ],
            "access_token": accessToken,
        ]
        return try serialize(topic: topic, event: "phx_join", payload: payload, ref: ref)
    }

    /// Build phx_leave frame.
    static func phxLeave(topic: String, ref: String) throws -> String {
        try serialize(topic: topic, event: "phx_leave", payload: [:], ref: ref)
    }

    /// Build heartbeat frame (Phoenix uses topic "phoenix" + event "heartbeat").
    /// Included as builder for D.5; not consumed by D.4 dispatch.
    static func heartbeat(ref: String) throws -> String {
        try serialize(topic: "phoenix", event: "heartbeat", payload: [:], ref: ref)
    }

    /// Build an access_token refresh frame (Phoenix Realtime allows token rotation
    /// in-place without rejoin via `event="access_token"` on the channel topic).
    static func accessTokenRefresh(topic: String, accessToken: String, ref: String) throws -> String {
        try serialize(
            topic: topic,
            event: "access_token",
            payload: ["access_token": accessToken],
            ref: ref
        )
    }

    private static func serialize(topic: String, event: String, payload: [String: Any], ref: String) throws -> String {
        let dict: [String: Any] = [
            "topic": topic,
            "event": event,
            "payload": payload,
            "ref": ref,
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        } catch {
            throw RealtimeError.encodingFailed(reason: "phoenix-frame: \(error)")
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw RealtimeError.encodingFailed(reason: "phoenix-frame: utf8")
        }
        return json
    }
}
