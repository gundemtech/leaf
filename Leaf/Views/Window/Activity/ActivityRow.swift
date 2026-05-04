import SwiftUI
import LeafCore

struct ActivityRow: View {
    let entry: ActivityFeedEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProviderIcon(entry: entry)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(providerLabel)
                        .font(.leafCaption)
                        .foregroundStyle(.leafMuted)
                        .textCase(.uppercase)
                        .kerning(0.6)
                    Text(displayPrimary)
                        .font(.leafBody)
                        .foregroundStyle(.leafInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let secondary = entry.secondaryText, !secondary.isEmpty {
                    Text(secondary)
                        .font(.leafCaption)
                        .foregroundStyle(.leafMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(relativeTime)
                .font(.leafCaption.monospacedDigit())
                .foregroundStyle(.leafMuted)
                .lineLimit(1)
        }
    }

    private var providerLabel: String {
        switch entry.provider {
        case .local:   return "Local"
        case .linear:  return "Linear"
        case .github:  return "GitHub"
        case .slack:   return "Slack"
        case .ai:      return "AI"
        case .unknown: return "Event"
        }
    }

    private var displayPrimary: String {
        if entry.provider == .local, let bundleID = entry.bundleID,
           entry.primaryText == bundleID {
            return AppNameResolver.shared.displayName(for: bundleID)
        }
        return entry.primaryText
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

// MARK: - Provider icon

private struct ProviderIcon: View {
    let entry: ActivityFeedEntry

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.leafInk.opacity(0.85))
        }
    }

    private var symbol: String {
        // Per-event_kind specifics first, then provider fallback.
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
        case "commit_pushed": return "arrow.up.circle"
        case "pr_opened", "pr_closed", "pr_merged": return "arrow.triangle.pull"
        case "pr_review_comment_authored", "pr_review_thread_resolved", "review_submitted":
            return "checkmark.bubble"
        case "issue_opened", "issue_closed", "issue_comment_authored":
            return "ladybug"
        case "branch_created", "branch_deleted": return "arrow.triangle.branch"
        case "tag_created", "release_published": return "tag.fill"
        case "discussion_authored", "discussion_comment_authored": return "text.bubble"
        case "actions_run_initiated": return "gearshape.2"
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

    private var background: Color {
        switch entry.provider {
        case .local:   return Color.leafCard.opacity(0.85)
        case .linear:  return Color.purple.opacity(0.18)
        case .github:  return Color.leafInk.opacity(0.10)
        case .slack:   return Color.green.opacity(0.18)
        case .ai:      return Color.leafAccent.opacity(0.22)
        case .unknown: return Color.leafCard.opacity(0.6)
        }
    }
}
