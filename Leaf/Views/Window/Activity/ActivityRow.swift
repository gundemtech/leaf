//
//  ActivityRow.swift
//  Track 2 / D3 — Activity row for one ActivityFeedEntry (raw event from
//  local/linear/github/slack/ai). Migrated from old palette + decorative
//  ProviderIcon (purple-Linear / green-Slack chip backgrounds). On D1:
//  neutral ProviderIcon (LeafColor.surface.inset background, LeafColor.text.
//  tertiary symbol tint) + LeafListRow. Provider identity carries via
//  uppercase tag inline with primary text. ×N coalesce count folded into
//  primary text per spec § OQ-2.
//

import SwiftUI
import LeafCore

struct ActivityRow: View {
    let entry: ActivityFeedEntry

    var body: some View {
        LeafListRow(
            primary: composedPrimary,
            secondary: secondaryText
        ) {
            ProviderIcon(entry: entry)
                .frame(width: LeafSpace.xxl, height: LeafSpace.xxl)   // 32×32
        } trailing: {
            Text(relativeTime)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .lineLimit(1)
        }
    }

    private var composedPrimary: String {
        let resolved: String = {
            if entry.provider == .local,
               let bundleID = entry.bundleID,
               entry.primaryText == bundleID {
                return AppNameResolver.shared.displayName(for: bundleID)
            }
            return entry.primaryText
        }()
        let suffix = entry.mergedCount > 1 ? " ×\(entry.mergedCount)" : ""
        return "\(providerLabel) · \(resolved)\(suffix)"
    }

    private var secondaryText: String? {
        guard let s = entry.secondaryText, !s.isEmpty else { return nil }
        return s
    }

    private var providerLabel: String {
        switch entry.provider {
        case .local:   return "LOCAL"
        case .linear:  return "LINEAR"
        case .github:  return "GITHUB"
        case .slack:   return "SLACK"
        case .ai:      return "AI"
        case .unknown: return "EVENT"
        }
    }

    private var relativeTime: String {
        let interval = Date().timeIntervalSince(entry.timestamp)
        if interval < 60 { return "just now" }
        if interval < 3600 {
            let m = Int(interval / 60)
            return "\(m)m ago"
        }
        if interval < 86_400 {
            let h = Int(interval / 3600)
            return "\(h)h ago"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: entry.timestamp)
    }
}

// MARK: - Provider icon (neutralised)

private struct ProviderIcon: View {
    let entry: ActivityFeedEntry

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                .fill(LeafColor.surface.inset)
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    private var symbol: String {
        switch entry.eventKind {
        case "status_transition": return "arrow.right.circle"
        case "linear_priority_changed": return "exclamationmark.triangle"
        case "linear_label_added", "linear_label_removed": return "tag"
        case "linear_assignee_changed": return "person.crop.circle"
        case "linear_cycle_changed": return "arrow.triangle.2.circlepath"
        case "linear_estimate_changed": return "ruler"
        case "linear_comment_authored": return "bubble.left"
        case "linear_document_edited": return "doc.text"
        case "linear_project_update_authored": return "megaphone"
        case "linear_initiative_observed": return "flag"
        case "issue_updated": return "list.bullet.clipboard"
        case GitHubEventKindKey.commitPushed.rawValue: return "arrow.up.circle"
        case GitHubEventKindKey.prOpened.rawValue,
             GitHubEventKindKey.prClosed.rawValue,
             GitHubEventKindKey.prMerged.rawValue:
            return "arrow.triangle.pull"
        case GitHubEventKindKey.prReviewCommentAuthored.rawValue,
             GitHubEventKindKey.prReviewThreadResolved.rawValue,
             GitHubEventKindKey.prReviewSubmitted.rawValue:
            return "checkmark.bubble"
        case GitHubEventKindKey.issueOpened.rawValue,
             GitHubEventKindKey.issueClosed.rawValue,
             GitHubEventKindKey.issueCommentAuthored.rawValue:
            return "ladybug"
        case GitHubEventKindKey.branchCreated.rawValue,
             GitHubEventKindKey.branchDeleted.rawValue:
            return "arrow.triangle.branch"
        case GitHubEventKindKey.tagCreated.rawValue,
             GitHubEventKindKey.releasePublished.rawValue:
            return "tag.fill"
        case GitHubEventKindKey.discussionAuthored.rawValue,
             GitHubEventKindKey.discussionCommentAuthored.rawValue:
            return "text.bubble"
        case GitHubEventKindKey.actionsRunInitiated.rawValue: return "gearshape.2"
        case "message_authored_aggregate", "slack_thread_reply_aggregate": return "message"
        case "slack_mention_received_aggregate": return "at"
        case "slack_file_uploaded_aggregate": return "paperclip"
        case "huddle_state_change": return "person.wave.2"
        case "slack_status_change": return "face.smiling"
        default: break
        }
        switch entry.provider {
        case .local:   return "app.dashed"
        case .linear:  return "circle.hexagonpath"
        case .github:  return "chevron.left.forwardslash.chevron.right"
        case .slack:   return "bubble.left.and.bubble.right"
        case .ai:      return "sparkles"
        case .unknown: return "circle"
        }
    }
}
