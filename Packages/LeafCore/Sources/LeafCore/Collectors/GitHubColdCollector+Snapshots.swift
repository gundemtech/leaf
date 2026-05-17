//
//  GitHubColdCollector+Snapshots.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — snapshot read/encode helpers + internal
//  Codable wrappers (mirror Linear D1 pattern: keep value types free of
//  Codable and confine JSON shape decisions to the collector).
//

import Foundation

extension GitHubColdCollector {
    // Internal Codable wrappers (mirror Linear D1 pattern: keep value types
    // free of Codable and confine JSON shape decisions to the collector).

    struct StarredSnapshotJSON: Codable {
        let repos: [String]
    }
    struct WatchedSnapshotJSON: Codable {
        let repos: [String]
    }
    struct AlertsSnapshotJSON: Codable {
        struct A: Codable {
            let kind: String
            let repoFullName: String
            let alertNumber: Int
            let severity: String
            let rule: String
            let packageName: String?
            let state: String
            let createdAtMs: Int64
            let updatedAtMs: Int64
        }
        let alerts: [A]
    }
    struct AuditCursorJSON: Codable {
        let since: Int64?
    }

    func snapshotRowPresent(kind: String) -> Bool {
        do {
            return try database.readSQL { raw in
                try ProviderSnapshotsStore.read(
                    provider: "github", snapshotKind: kind, in: raw
                ) != nil
            }
        } catch {
            return false
        }
    }

    func readStarredSnapshot() -> [String] {
        guard let snap = readRawSnapshot(Schema.ProviderSnapshotKinds.githubStarredRepos) else { return [] }
        return (try? JSONDecoder().decode(StarredSnapshotJSON.self, from: Data(snap.snapshotJSON.utf8)).repos) ?? []
    }

    func readWatchedSnapshot() -> [String] {
        guard let snap = readRawSnapshot(Schema.ProviderSnapshotKinds.githubWatchedRepos) else { return [] }
        return (try? JSONDecoder().decode(WatchedSnapshotJSON.self, from: Data(snap.snapshotJSON.utf8)).repos) ?? []
    }

    func readAlertsSnapshot(kind: String) -> [GitHubSecurityAlertSnapshot] {
        guard let snap = readRawSnapshot(kind) else { return [] }
        guard let parsed = try? JSONDecoder().decode(AlertsSnapshotJSON.self, from: Data(snap.snapshotJSON.utf8)) else {
            return []
        }
        return parsed.alerts.compactMap { a in
            guard let k = GitHubSecurityAlertSnapshot.Kind(rawValue: a.kind) else { return nil }
            return GitHubSecurityAlertSnapshot(
                kind: k, repoFullName: a.repoFullName, alertNumber: a.alertNumber,
                severity: a.severity, rule: a.rule, packageName: a.packageName,
                state: a.state, createdAtMs: a.createdAtMs, updatedAtMs: a.updatedAtMs
            )
        }
    }

    func readAuditCursor() -> Int64? {
        guard let snap = readRawSnapshot(Schema.ProviderSnapshotKinds.githubAuditCursor) else { return nil }
        return (try? JSONDecoder().decode(AuditCursorJSON.self, from: Data(snap.snapshotJSON.utf8)).since)
    }

    func readRawSnapshot(_ kind: String) -> ProviderSnapshot? {
        let outer: ProviderSnapshot?? = try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(provider: "github", snapshotKind: kind, in: raw)
        }
        return outer.flatMap { $0 }
    }

    func makeStarredSnapshot(_ repos: [String], capturedAtMs: Int64) -> ProviderSnapshot {
        let payload = StarredSnapshotJSON(repos: repos)
        let s = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"repos\":[]}"
        return ProviderSnapshot(
            provider: "github",
            snapshotKind: Schema.ProviderSnapshotKinds.githubStarredRepos,
            snapshotJSON: s, capturedAtMs: capturedAtMs
        )
    }

    func makeWatchedSnapshot(_ repos: [String], capturedAtMs: Int64) -> ProviderSnapshot {
        let payload = WatchedSnapshotJSON(repos: repos)
        let s = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"repos\":[]}"
        return ProviderSnapshot(
            provider: "github",
            snapshotKind: Schema.ProviderSnapshotKinds.githubWatchedRepos,
            snapshotJSON: s, capturedAtMs: capturedAtMs
        )
    }

    func makeAlertsSnapshot(
        snapshotKind: String, alerts: [GitHubSecurityAlertSnapshot], capturedAtMs: Int64
    ) -> ProviderSnapshot {
        let payload = AlertsSnapshotJSON(
            alerts: alerts.map { a in
                .init(
                    kind: a.kind.rawValue, repoFullName: a.repoFullName, alertNumber: a.alertNumber,
                    severity: a.severity, rule: a.rule, packageName: a.packageName,
                    state: a.state, createdAtMs: a.createdAtMs, updatedAtMs: a.updatedAtMs
                )
            })
        let s = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"alerts\":[]}"
        return ProviderSnapshot(
            provider: "github", snapshotKind: snapshotKind,
            snapshotJSON: s, capturedAtMs: capturedAtMs
        )
    }

    func makeAuditCursorSnapshot(since: Int64?, capturedAtMs: Int64) -> ProviderSnapshot {
        let payload = AuditCursorJSON(since: since)
        let s = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"since\":null}"
        return ProviderSnapshot(
            provider: "github",
            snapshotKind: Schema.ProviderSnapshotKinds.githubAuditCursor,
            snapshotJSON: s, capturedAtMs: capturedAtMs
        )
    }
}
