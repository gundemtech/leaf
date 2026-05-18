//
//  RealtimeEvent.swift
//  LeafCore
//
//  Track 5 / S7 — Output stream type for `RealtimeWebSocketDriver`. Wraps the
//  4 dispatch outcomes the driver emits via AsyncStream:
//   • `channelJoined` — phx_join ack received (status="ok")
//   • `channelRejected` — phx_join nack received (status="error")
//   • `teamEventInserted` — postgres_changes INSERT on team_events
//   • `directMessageInserted` — postgres_changes INSERT on direct_messages
//   • `directMessageUpdated` — postgres_changes UPDATE on direct_messages (e.g., read_at set)
//   • `disconnected` — transport closed / phx_close / receive error
//
//  Wire-shape rows (`SupabaseTeamEventRow` / `SupabaseDirectMessageRow`) carry
//  ENCRYPTED payloads. Downstream consumers (LeafRealtimeService, Phase D.5+)
//  resolve teamKey by keyID, decrypt to plaintext, then route to:
//     • `DirectMessageInboxService.absorbRealtimePush(_:)`
//     • `TeamEventMirrorService.absorbRealtimePush(_:)`
//

import Foundation

public enum RealtimeEvent: Sendable, Equatable {
    /// phx_join ack received for the topic; channel is live.
    case channelJoined(topic: String)
    /// phx_join was rejected (e.g., RLS denied / token invalid).
    case channelRejected(topic: String, reason: String)
    /// INSERT event on team_events table — encrypted-wire shape.
    case teamEventInserted(record: SupabaseTeamEventRow)
    /// INSERT event on direct_messages table — encrypted-wire shape.
    case directMessageInserted(record: SupabaseDirectMessageRow)
    /// UPDATE event on direct_messages table (read receipts etc).
    case directMessageUpdated(record: SupabaseDirectMessageRow)
    /// Transport-level disconnect (WS closed, phx_close, receive error).
    case disconnected(reason: String)
}

public enum RealtimeError: Error, Sendable, Equatable {
    /// Driver not in `.connected` state at call site.
    case notConnected
    /// JSON serialization of outbound frame failed.
    case encodingFailed(reason: String)
    /// JSON decode of inbound frame failed (silent-skipped at dispatch; raised only at top-level surfaces).
    case decodingFailed(reason: String)
    /// phx_reply with status="error" for our phx_join.
    case channelJoinRejected(reason: String)
}
