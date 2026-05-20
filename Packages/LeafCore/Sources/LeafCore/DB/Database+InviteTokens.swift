//
//  Database+InviteTokens.swift
//  LeafCore
//
//  M027 invite-redesign — public Database accessors over `InviteTokenStore`.
//  Mirrors the existing pattern (e.g., `setNotificationPref` wrapping
//  `NotificationPrefsStore.setEnabled`). Public methods wrap writeSQL/readSQL
//  so callers outside LeafCore tests don't need internal pool access.
//

import Foundation
import GRDB

extension Database {

    /// INSERT a fresh local mirror row. Throws on CHECK violation or PK conflict.
    /// Pre-flight 10-active cap enforcement is the caller's responsibility
    /// (`InviteTokenService.generate` performs count + insert in one tx via
    /// `insertInviteTokenCappedAtMaxActive`).
    public func insertInviteToken(_ token: InviteToken) throws {
        try writeSQL { db in
            try InviteTokenStore.insert(token, in: db)
        }
    }

    /// UPSERT for refresh-from-server reconciliation (label / used_count /
    /// deleted_at columns may diverge between client and server).
    public func upsertInviteToken(_ token: InviteToken) throws {
        try writeSQL { db in
            try InviteTokenStore.upsert(token, in: db)
        }
    }

    public func fetchInviteToken(code: String) throws -> InviteToken? {
        try readSQL { db in
            try InviteTokenStore.fetch(code: code, in: db)
        }
    }

    public func listActiveInviteTokens(workspaceID: String, now: Date = Date()) throws -> [InviteToken] {
        try readSQL { db in
            try InviteTokenStore.listActive(workspaceID: workspaceID, now: now, in: db)
        }
    }

    public func listAllInviteTokens(workspaceID: String) throws -> [InviteToken] {
        try readSQL { db in
            try InviteTokenStore.listAll(workspaceID: workspaceID, in: db)
        }
    }

    public func countActiveInviteTokens(workspaceID: String, now: Date = Date()) throws -> Int {
        try readSQL { db in
            try InviteTokenStore.countActive(workspaceID: workspaceID, now: now, in: db)
        }
    }

    /// Atomic count-then-insert. Throws `InviteTokenError.maxActiveTokensReached`
    /// if the workspace already has `InviteTokenStore.maxActiveTokensPerWorkspace`
    /// active tokens (per spec §7).
    public func insertInviteTokenCappedAtMaxActive(_ token: InviteToken, now: Date = Date()) throws {
        try writeSQL { db in
            let active = try InviteTokenStore.countActive(
                workspaceID: token.workspaceID, now: now, in: db
            )
            guard active < InviteTokenStore.maxActiveTokensPerWorkspace else {
                throw InviteTokenError.maxActiveTokensReached
            }
            try InviteTokenStore.insert(token, in: db)
        }
    }

    public func markInviteTokenDeleted(code: String, at: Date) throws {
        try writeSQL { db in
            try InviteTokenStore.markDeleted(code: code, at: at, in: db)
        }
    }
}
