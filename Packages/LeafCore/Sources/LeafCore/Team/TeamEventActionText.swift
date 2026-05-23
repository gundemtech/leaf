//
//  TeamEventActionText.swift
//  LeafCore
//
//  M-IX — action-text derivation for a single team-event row. Moved out of
//  LeafFeedRow (app target) so it can be precomputed once in the feed mapping
//  layer (RenderedTeamEvent) instead of parsed per row per render.
//
//  ADR-010 discipline: only allow-listed payload keys are read (title,
//  *_excerpt). Never reads AI-related fields or PII; never logs raw values.
//

import Foundation

public enum TeamEventActionText {

    /// Best-effort action text for an individual team-event row.
    public static func make(for row: TeamEventMirrorRow) -> String {
        let payload = parsePayload(row.plaintextPayloadJSON)

        switch row.source {
        case .gitCommits:
            if let title = payload["title"] as? String, !title.isEmpty {
                return "pushed \"\(title)\""
            }
            return "pushed a commit"

        case .linearIssues:
            if let title = payload["title"] as? String, !title.isEmpty {
                return "updated \"\(title)\""
            }
            return "updated an issue"

        case .slackMentions:
            return "mentioned you"

        case .githubPRs:
            if let title = payload["title"] as? String, !title.isEmpty {
                return "opened PR \"\(title)\""
            }
            return "opened a pull request"

        case .detectedDecisions:
            if let excerpt = payload["reasoning_excerpt"] as? String, !excerpt.isEmpty {
                let trimmed = String(excerpt.prefix(50))
                return "decision: \(trimmed)…"
            }
            return "made a decision"

        case .detectedBlockers:
            if let excerpt = payload["blocker_excerpt"] as? String, !excerpt.isEmpty {
                let trimmed = String(excerpt.prefix(50))
                return "blocker: \(trimmed)…"
            }
            return "hit a blocker"

        case .detectedOpenQuestions:
            if let excerpt = payload["question_excerpt"] as? String, !excerpt.isEmpty {
                let trimmed = String(excerpt.prefix(50))
                return "question: \(trimmed)…"
            }
            return "raised a question"

        case .detectedWhereStopped:
            if let excerpt = payload["excerpt"] as? String, !excerpt.isEmpty {
                let trimmed = String(excerpt.prefix(50))
                return "stopped at: \(trimmed)…"
            }
            return "stopped work"

        case .rawGitHubActivity:
            return "GitHub activity"
        }
    }

    /// Best-effort JSON payload parse. Returns empty dict on failure.
    /// Only call with allow-listed keys; never log or surface raw values.
    private static func parsePayload(_ json: String) -> [String: Any] {
        guard
            let data = json.data(using: .utf8),
            let obj  = try? JSONSerialization.jsonObject(with: data),
            let dict = obj as? [String: Any]
        else { return [:] }
        return dict
    }
}
