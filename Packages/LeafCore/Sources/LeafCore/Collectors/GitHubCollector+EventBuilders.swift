//
//  GitHubCollector+EventBuilders.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — static event builders for GitHub
//  presence/state pulse events. Pure relocation from GitHubCollector.swift.
//

import Foundation

extension GitHubCollector {
    /// Phase 4.7.B-1 — `gh_notifications_pulse` state event. Эмитится КАЖДЫЙ tick
    /// (даже при empty inbox) — нулевой count всё равно signal: "пользователь дочистил
    /// inbox". `signal_type=.context` (state pulse, не user action).
    /// Reasons распакованы в top-level keys (`reason_review_requested_count`) для
    /// query-friendly доступа без nested JSON parsing на read-side.
    static func makeNotificationsPulseEvent(
        summary: GitHubNotificationsSummary, nowMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.notificationsPulse.rawValue,
            "total_unread": String(summary.totalUnread),
            "observed_at_ms": String(nowMs),
        ]
        // Top-level fields для query-friendly access (избегаем nested JSON в payload).
        for (reason, count) in summary.byReason {
            payload["reason_\(reason)_count"] = String(count)
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-2 — `gh_pr_awaiting_review_count` state event. Эмитится каждый tick.
    /// `signal_type=.context` (state pulse). `top_repo` поле omitted при `count==0`
    /// или `topRepo==nil` — отличает "нет данных" от "owner/repo:0".
    static func makePRAwaitingReviewCountEvent(
        summary: GitHubReviewQueueSummary, nowMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.prAwaitingReviewCount.rawValue,
            "count": String(summary.count),
            "observed_at_ms": String(nowMs),
        ]
        if let topRepo = summary.topRepo {
            payload["top_repo"] = topRepo
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-3 — `gh_actions_run_initiated` action event per snapshot.
    /// `signal_type=.action` (discrete action — юзер запустил CI run), не `.context`.
    /// Timestamp = run's `created_at` (когда GitHub registered run start), не nowMs —
    /// синхронизируется с реальным moment of action для downstream timeline accuracy.
    /// ADR-010: `head_commit.message` / run `name` (часто equals commit subject) /
    /// `output.title` — НЕ persisted. Только public-safe metadata: workflow file slug,
    /// trigger event, status/conclusion enum, head branch.
    static func makeActionsRunInitiatedEvent(snapshot: GitHubActionsRunSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.actionsRunInitiated.rawValue,
            "run_id": String(snapshot.runID),
            "repo": snapshot.repo,
            "workflow_name": snapshot.workflowName,
            "event": snapshot.event,
            "status": snapshot.status,
            "created_at_ms": String(snapshot.createdAtMs),
        ]
        // Только non-nil поля — отличает "completed→success" от "in_progress" (no
        // conclusion yet) на read-side без nullable parsing.
        if let conclusion = snapshot.conclusion {
            payload["conclusion"] = conclusion
        }
        if let branch = snapshot.headBranch {
            payload["head_branch"] = branch
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(snapshot.createdAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-4 — `gh_check_runs_status` state event per (repo, sha) pair.
    /// `signal_type=.context` (state pulse — current CI status of HEAD commit,
    /// не discrete user action). Timestamp = `nowMs` (when collector observed),
    /// не `created_at` of run (this is aggregate snapshot across N runs).
    /// ADR-010: ни `name` of check-run, ни `output.title`/`output.summary`/
    /// `output.text` — provider их не parses, collector их не emit'ит. Только
    /// 5 aggregate counts (total + 4 buckets) + repo + sha identifiers.
    static func makeCheckRunsStatusEvent(
        repo: String, sha: String, summary: GitHubCheckRunsSummary, nowMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.checkRunsStatus.rawValue,
            "repo": repo,
            "sha": sha,
            "total": String(summary.total),
            "success": String(summary.success),
            "failure": String(summary.failure),
            "in_progress": String(summary.inProgress),
            "neutral": String(summary.neutral),
            "observed_at_ms": String(nowMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-2 — `gh_my_open_pr_count` state event. Эмитится каждый tick.
    /// `signal_type=.context` (state pulse).
    static func makeMyOpenPRCountEvent(
        summary: GitHubMyOpenPRsSummary, nowMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.myOpenPRCount.rawValue,
            "count": String(summary.count),
            "observed_at_ms": String(nowMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    static func makeEvent(snapshot: GitHubEventSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": snapshot.eventKind,
            "repo": snapshot.repoFullName,
            "title": snapshot.title,
            "number": snapshot.number.map(String.init) ?? "",
            "sha": snapshot.sha ?? "",
            "branch": snapshot.branch ?? "",
        ]
        // Phase 4.6.A.1 — latency fields. Только non-nil → ключ присутствует;
        // отсутствие ключа в payload отличает "не знаем" от "0 секунд".
        if let cycle = snapshot.cycleSeconds {
            payload["cycle_seconds"] = String(cycle)
        }
        if let delay = snapshot.reviewDelaySeconds {
            payload["review_delay_seconds"] = String(delay)
        }
        // Phase 4.7.A — per-event-kind extension fields. Reserved baseline keys
        // ("source"/"event_kind"/"repo"/"title"/"number"/"sha"/"branch"/
        // "cycle_seconds"/"review_delay_seconds" + Track-1 D1 body/PR metadata keys)
        // cannot be overridden via metadata — guards против accidental shadowing.
        // Other keys merge in.
        if let metadata = snapshot.metadata {
            let reserved: Set<String> = [
                "source", "event_kind", "repo", "title", "number", "sha", "branch",
                "cycle_seconds", "review_delay_seconds",
                // Track-1 D1 — body + PR metadata keys also reserved
                Schema.EventPayloadKeys.body,
                Schema.EventPayloadKeys.bodyTruncated,
                Schema.EventPayloadKeys.attachmentsJson,
                Schema.EventPayloadKeys.filesCount,
                Schema.EventPayloadKeys.additions,
                Schema.EventPayloadKeys.deletions,
                Schema.EventPayloadKeys.requestedReviewersJson,
                Schema.EventPayloadKeys.mentionCount,
                Schema.EventPayloadKeys.linkCount,
            ]
            for (key, value) in metadata where !reserved.contains(key) {
                payload[key] = value
            }
        }
        // Track-1 D1 — body + bodyTruncated (BodyCap-applied at moat boundary).
        if let body = snapshot.body, !body.isEmpty {
            payload[Schema.EventPayloadKeys.body] = body
            if snapshot.bodyTruncated {
                payload[Schema.EventPayloadKeys.bodyTruncated] = "true"
            }
        }
        // Track-1 D1 / Phase 4.8 — PR metadata payload keys.
        if let pr = snapshot.prMetadata {
            payload[Schema.EventPayloadKeys.filesCount] = String(pr.filesCount)
            payload[Schema.EventPayloadKeys.additions] = String(pr.additions)
            payload[Schema.EventPayloadKeys.deletions] = String(pr.deletions)
            payload[Schema.EventPayloadKeys.mentionCount] = String(pr.mentionCount)
            payload[Schema.EventPayloadKeys.linkCount] = String(pr.linkCount)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(pr.requestedReviewers),
                let str = String(data: data, encoding: .utf8)
            {
                payload[Schema.EventPayloadKeys.requestedReviewersJson] = str
            }
        }
        // Track-1 D1 — attachments (release.assets + inline images from PR/comment bodies).
        if !snapshot.attachments.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(snapshot.attachments),
                let str = String(data: data, encoding: .utf8)
            {
                payload[Schema.EventPayloadKeys.attachmentsJson] = str
            }
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(snapshot.createdAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }
}
