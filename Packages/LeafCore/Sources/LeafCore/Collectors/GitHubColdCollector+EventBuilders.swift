//
//  GitHubColdCollector+EventBuilders.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — static event builders + pure diff
//  helpers + repo name parsing for the cold-tier GitHub collector. Pure
//  relocation from GitHubColdCollector.swift.
//

import Foundation

extension GitHubColdCollector {
    // MARK: - Repo full-name parsing

    static func parseRepoFullName(_ name: String) -> (owner: String, repo: String)? {
        let parts = name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    // MARK: - Diff helpers (pure)

    /// Returns repos appearing in `current` but not `prior` (= starred) and
    /// vice versa (= unstarred). Inputs are lists of `repoFullName` strings.
    public static func starredDiff(
        prior: [String], current: [String]
    ) -> (starred: [String], unstarred: [String]) {
        let priorSet = Set(prior)
        let currentSet = Set(current)
        let starred = Array(currentSet.subtracting(priorSet)).sorted()
        let unstarred = Array(priorSet.subtracting(currentSet)).sorted()
        return (starred, unstarred)
    }

    /// Same shape as `starredDiff` — repos appearing in `current` but not
    /// `prior` are watched, vice versa unwatched.
    public static func watchedDiff(
        prior: [String], current: [String]
    ) -> (watched: [String], unwatched: [String]) {
        let priorSet = Set(prior)
        let currentSet = Set(current)
        let watched = Array(currentSet.subtracting(priorSet)).sorted()
        let unwatched = Array(priorSet.subtracting(currentSet)).sorted()
        return (watched, unwatched)
    }

    /// Composite key = (kind, repoFullName, alertNumber).
    /// `observed` = current \ prior (by composite key), plus rows whose prior
    /// state was resolved/fixed/dismissed AND current state is open
    /// (re-observation).
    /// `resolved` = prior \ current, plus rows whose state transitioned from
    /// open to fixed/resolved/dismissed.
    public static func securityAlertsDiff(
        prior: [GitHubSecurityAlertSnapshot],
        current: [GitHubSecurityAlertSnapshot]
    ) -> (observed: [GitHubSecurityAlertSnapshot], resolved: [GitHubSecurityAlertSnapshot]) {
        struct Key: Hashable {
            let kind: GitHubSecurityAlertSnapshot.Kind
            let repo: String
            let number: Int
        }
        let priorByKey = Dictionary(
            uniqueKeysWithValues: prior.map { (Key(kind: $0.kind, repo: $0.repoFullName, number: $0.alertNumber), $0) })
        let currentByKey = Dictionary(
            uniqueKeysWithValues: current.map {
                (Key(kind: $0.kind, repo: $0.repoFullName, number: $0.alertNumber), $0)
            })
        let resolvedStates: Set<String> = ["fixed", "resolved", "dismissed"]
        let openStates: Set<String> = ["open"]

        var observed: [GitHubSecurityAlertSnapshot] = []
        var resolved: [GitHubSecurityAlertSnapshot] = []

        for (k, c) in currentByKey {
            if let p = priorByKey[k] {
                // State transition.
                if resolvedStates.contains(p.state) && openStates.contains(c.state) {
                    observed.append(c)
                } else if openStates.contains(p.state) && resolvedStates.contains(c.state) {
                    resolved.append(c)
                }
            } else {
                // Brand new key — observed.
                observed.append(c)
            }
        }
        for (k, p) in priorByKey where currentByKey[k] == nil {
            // Disappeared from current → resolved (treat as cleared).
            resolved.append(p)
        }
        return (
            observed.sorted(by: alertOrder),
            resolved.sorted(by: alertOrder)
        )
    }

    static func alertOrder(_ a: GitHubSecurityAlertSnapshot, _ b: GitHubSecurityAlertSnapshot) -> Bool {
        if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue < b.kind.rawValue }
        if a.repoFullName != b.repoFullName { return a.repoFullName < b.repoFullName }
        return a.alertNumber < b.alertNumber
    }

    // MARK: - Event builders

    static func makeRepoStarredEvent(
        repoFullName: String, starredAtMs: Int64, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.repoStarred.rawValue,
            Schema.EventPayloadKeys.repoFullName: repoFullName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(starredAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeRepoUnstarredEvent(
        repoFullName: String, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.repoUnstarred.rawValue,
            Schema.EventPayloadKeys.repoFullName: repoFullName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeRepoWatchedEvent(
        repoFullName: String, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.repoWatched.rawValue,
            Schema.EventPayloadKeys.repoFullName: repoFullName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeRepoUnwatchedEvent(
        repoFullName: String, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.repoUnwatched.rawValue,
            Schema.EventPayloadKeys.repoFullName: repoFullName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeSecurityAlertEvent(
        eventKind: GitHubEventKindKey,
        alert: GitHubSecurityAlertSnapshot,
        observedAtMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": eventKind.rawValue,
            Schema.EventPayloadKeys.repoFullName: alert.repoFullName,
            Schema.EventPayloadKeys.alertNumber: String(alert.alertNumber),
            Schema.EventPayloadKeys.alertSeverity: alert.severity,
            Schema.EventPayloadKeys.alertRule: alert.rule,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        if let pkg = alert.packageName {
            payload[Schema.EventPayloadKeys.dependabotPackageName] = pkg
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeAuditActionObservedEvent(
        _ entry: GitHubAuditLogEntry, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.auditActionObserved.rawValue,
            Schema.EventPayloadKeys.auditAction: entry.action,
            Schema.EventPayloadKeys.auditActorLogin: entry.actorLogin,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(entry.createdAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }
}
