//
//  JoinRequest.swift
//  LeafCore
//
//  M027 invite-redesign — value type wrapping a single `join_requests` row.
//  Lives ONLY on Supabase (no local mirror) — admin's queue is fetched on
//  demand via `SupabaseClient.listPendingJoinRequests`, invitee's waiting
//  card via `SupabaseClient.fetchOwnJoinRequest`.
//

import Foundation

public struct JoinRequest: Equatable, Sendable, Codable {
    public let requestID: String
    public let workspaceID: String
    public let code: String
    public let inviteePubkeyHex: String
    public let inviteeDisplayName: String
    public let status: Status
    /// AES-GCM-sealed teamKey blob (S3 envelope v=1). Non-nil only when
    /// `status == .approved` (server CHECK constraint).
    public let encryptedTeamKey: Data?
    public let createdAt: Date
    public let decidedAt: Date?
    public let decidedByPubkeyHex: String?

    public enum Status: String, Sendable, Codable, Equatable {
        case pending, approved, declined, cancelled, expired
    }

    public init(
        requestID: String,
        workspaceID: String,
        code: String,
        inviteePubkeyHex: String,
        inviteeDisplayName: String,
        status: Status,
        encryptedTeamKey: Data? = nil,
        createdAt: Date,
        decidedAt: Date? = nil,
        decidedByPubkeyHex: String? = nil
    ) {
        self.requestID = requestID
        self.workspaceID = workspaceID
        self.code = code
        self.inviteePubkeyHex = inviteePubkeyHex
        self.inviteeDisplayName = inviteeDisplayName
        self.status = status
        self.encryptedTeamKey = encryptedTeamKey
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.decidedByPubkeyHex = decidedByPubkeyHex
    }
}
