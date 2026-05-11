//
//  GitHubAPISnapshots.swift
//  LeafCore
//
//  Phase Track-3 D2 — value types for the GitHub deep-sweep warm + cold tiers.
//  Sibling to GitHubAPIProvider.swift to keep that file under its size budget.
//
//  Privacy guardrail (ADR-010 §6): each type below captures public-safe /
//  structural metadata only. Bodies / free-form text content live in D1
//  capture; relay never sees these snapshots' fields either way (ProjectV2
//  item titles / Gist descriptions / audit actions are structurally narrow,
//  per-spec OK). Mirrors the D1 Linear convention: every type is
//  `public Sendable Hashable` with public init plus `static let empty`
//  (or `.empty(...)` factory) for graceful-degradation defaults.
//

import Foundation

// MARK: - ProjectsV2

public struct GitHubProjectV2ItemSnapshot: Sendable, Hashable, Codable {
    public let itemID: String
    public let projectID: String
    public let title: String
    public let status: String?
    public let iterationID: String?
    public let fieldValues: [String: String]
    public let updatedAtMs: Int64

    public init(itemID: String, projectID: String, title: String, status: String?, iterationID: String?, fieldValues: [String: String], updatedAtMs: Int64) {
        self.itemID = itemID; self.projectID = projectID; self.title = title
        self.status = status; self.iterationID = iterationID
        self.fieldValues = fieldValues; self.updatedAtMs = updatedAtMs
    }
}

public struct GitHubProjectV2Snapshot: Sendable, Hashable {
    public let projectID: String
    public let projectTitle: String
    public let items: [GitHubProjectV2ItemSnapshot]
    public init(projectID: String, projectTitle: String, items: [GitHubProjectV2ItemSnapshot]) {
        self.projectID = projectID; self.projectTitle = projectTitle; self.items = items
    }
}

public struct GitHubProjectsV2Snapshot: Sendable, Hashable {
    public let projects: [GitHubProjectV2Snapshot]
    public init(projects: [GitHubProjectV2Snapshot]) { self.projects = projects }
    public static let empty = GitHubProjectsV2Snapshot(projects: [])
}

// MARK: - Gists

public struct GitHubGistSnapshot: Sendable, Hashable, Codable {
    public let gistID: String
    public let description: String
    public let isPublic: Bool
    public let createdAtMs: Int64
    public let updatedAtMs: Int64
    public init(gistID: String, description: String, isPublic: Bool, createdAtMs: Int64, updatedAtMs: Int64) {
        self.gistID = gistID; self.description = description; self.isPublic = isPublic
        self.createdAtMs = createdAtMs; self.updatedAtMs = updatedAtMs
    }
}

// MARK: - Repo invitations

public struct GitHubRepoInvitationSnapshot: Sendable, Hashable, Codable {
    public let invitationID: String
    public let repoFullName: String
    public let inviterLogin: String
    public let invitedAtMs: Int64
    public init(invitationID: String, repoFullName: String, inviterLogin: String, invitedAtMs: Int64) {
        self.invitationID = invitationID; self.repoFullName = repoFullName
        self.inviterLogin = inviterLogin; self.invitedAtMs = invitedAtMs
    }
}

// MARK: - Codespaces

public struct GitHubCodespaceSnapshot: Sendable, Hashable, Codable {
    public let codespaceName: String
    public let repoFullName: String
    public let state: String
    public let createdAtMs: Int64
    public let lastUsedAtMs: Int64?
    public init(codespaceName: String, repoFullName: String, state: String, createdAtMs: Int64, lastUsedAtMs: Int64?) {
        self.codespaceName = codespaceName; self.repoFullName = repoFullName
        self.state = state; self.createdAtMs = createdAtMs; self.lastUsedAtMs = lastUsedAtMs
    }
}

// MARK: - Issue reactions

public struct GitHubIssueReactionsSnapshot: Sendable, Hashable, Codable {
    public let owner: String
    public let repo: String
    public let issueNumber: Int
    public let byEmoji: [String: Int]
    public let observedAtMs: Int64
    public init(owner: String, repo: String, issueNumber: Int, byEmoji: [String: Int], observedAtMs: Int64) {
        self.owner = owner; self.repo = repo; self.issueNumber = issueNumber
        self.byEmoji = byEmoji; self.observedAtMs = observedAtMs
    }
    public static func empty(owner: String, repo: String, issueNumber: Int, nowMs: Int64) -> GitHubIssueReactionsSnapshot {
        GitHubIssueReactionsSnapshot(owner: owner, repo: repo, issueNumber: issueNumber, byEmoji: [:], observedAtMs: nowMs)
    }
}

// MARK: - Starred / watched

public struct GitHubStarredRepoSnapshot: Sendable, Hashable {
    public let repoFullName: String
    public let starredAtMs: Int64
    public init(repoFullName: String, starredAtMs: Int64) {
        self.repoFullName = repoFullName; self.starredAtMs = starredAtMs
    }
}

public struct GitHubWatchedRepoSnapshot: Sendable, Hashable {
    public let repoFullName: String
    public init(repoFullName: String) { self.repoFullName = repoFullName }
}

// MARK: - Security alerts (shared shape across secret / code / dependabot)

public struct GitHubSecurityAlertSnapshot: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case secret, code, dependabot }
    public let kind: Kind
    public let repoFullName: String
    public let alertNumber: Int
    public let severity: String
    public let rule: String
    public let packageName: String?
    public let state: String
    public let createdAtMs: Int64
    public let updatedAtMs: Int64
    public init(kind: Kind, repoFullName: String, alertNumber: Int, severity: String, rule: String, packageName: String?, state: String, createdAtMs: Int64, updatedAtMs: Int64) {
        self.kind = kind; self.repoFullName = repoFullName; self.alertNumber = alertNumber
        self.severity = severity; self.rule = rule; self.packageName = packageName
        self.state = state; self.createdAtMs = createdAtMs; self.updatedAtMs = updatedAtMs
    }
}

// MARK: - Org membership / audit log

public struct GitHubOrgSnapshot: Sendable, Hashable {
    public let login: String
    public init(login: String) { self.login = login }
}

public struct GitHubAuditLogEntry: Sendable, Hashable {
    public let action: String
    public let actorLogin: String
    public let createdAtMs: Int64
    public init(action: String, actorLogin: String, createdAtMs: Int64) {
        self.action = action; self.actorLogin = actorLogin; self.createdAtMs = createdAtMs
    }
}

public struct GitHubOrgAuditLogBatch: Sendable, Hashable {
    public let entries: [GitHubAuditLogEntry]
    public let cursorMs: Int64?
    public init(entries: [GitHubAuditLogEntry], cursorMs: Int64?) {
        self.entries = entries; self.cursorMs = cursorMs
    }
    public static let empty = GitHubOrgAuditLogBatch(entries: [], cursorMs: nil)
}
