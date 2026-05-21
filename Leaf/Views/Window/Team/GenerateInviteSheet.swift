//
//  GenerateInviteSheet.swift
//  Leaf
//
//  M027 invite-redesign — admin generates a workspace-scoped invite token.
//  Single primitive (the LEAF-XXXX-XXXX-XXXX code) rendered as both a
//  clickable `leaf://invite/<code>` link AND a typeable short code.
//
//  Workflow:
//    1. Optional label + TTL picker (1h / 24h / 7d / 30d / Never) + single-use toggle
//    2. [Generate] → result card with copy-link + copy-code + countdown + approval-hint
//    3. [Done] dismisses
//

import AppKit
import LeafCore
import SwiftUI

struct GenerateInviteSheet: View {
  @Environment(InviteTokensReader.self) private var reader
  @Environment(WorkspaceReader.self) private var workspaceReader
  @Environment(\.dismiss) private var dismiss

  @State private var label: String = ""
  @State private var ttl: TTLPreset = .day1
  @State private var singleUse: Bool = false

  enum TTLPreset: String, CaseIterable, Identifiable, Hashable {
    case hour1 = "1 hour"
    case day1 = "24 hours"
    case days7 = "7 days"
    case days30 = "30 days"
    case forever = "Never expires"

    var id: String { rawValue }

    /// Seconds. 0 sentinel = «Never expires» — InviteTokenService translates
    /// this to nil expires_at on the row.
    var seconds: Int {
      switch self {
      case .hour1: return 3600
      case .day1: return 86400
      case .days7: return 7 * 86400
      case .days30: return 30 * 86400
      case .forever: return 0
      }
    }
  }

  var body: some View {
    LeafSheetLayout(title: "Generate invite", onDismiss: { dismiss() }) {
      VStack(alignment: .leading, spacing: LeafSpace.xl) {
        content
        Spacer(minLength: 0)
        footer
      }
    }
    .onDisappear { reader.dismissReady() }
  }

  @ViewBuilder
  private var content: some View {
    switch reader.state {
    case .idle, .loaded, .loading, .error:
      formCard
      if case .error(let m) = reader.state {
        LeafBanner(tone: .danger, title: "Couldn't generate invite", description: m)
      }
    case .generating:
      formCard
        .disabled(true)
        .opacity(0.5)
      HStack {
        Spacer()
        ProgressView()
        Spacer()
      }
    case .ready(let token):
      readyOutput(token: token)
    }
  }

  // MARK: - Form (idle / pre-generate)

  @ViewBuilder
  private var formCard: some View {
    LeafCard(variant: .raised, padding: .regular) {
      VStack(alignment: .leading, spacing: LeafSpace.md) {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
          Text("LABEL (OPTIONAL)").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
          TextField("Team kickoff", text: $label)
            .textFieldStyle(.roundedBorder)
          Text("Use to distinguish multiple active tokens.")
            .font(LeafType.caption)
            .foregroundStyle(LeafColor.text.tertiary)
        }

        VStack(alignment: .leading, spacing: LeafSpace.xs) {
          Text("TTL").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
          Picker("TTL", selection: $ttl) {
            ForEach(TTLPreset.allCases) { preset in
              Text(preset.rawValue).tag(preset)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
        }

        Toggle(isOn: $singleUse) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Single-use")
              .font(LeafType.body.regular)
              .foregroundStyle(LeafColor.text.primary)
            Text("Token expires after 1 use")
              .font(LeafType.caption)
              .foregroundStyle(LeafColor.text.tertiary)
          }
        }
        .toggleStyle(.switch)
      }
    }
  }

  // MARK: - Ready output (post-generate)

  @ViewBuilder
  private func readyOutput(token: InviteToken) -> some View {
    VStack(alignment: .leading, spacing: LeafSpace.lg) {
      // Single share card — code is the primitive; link is just
      // `leaf://invite/<code>`. Two copy buttons cover both delivery
      // channels (chat / phone) without duplicating the data display.
      LeafCard(variant: .raised, padding: .regular) {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
          Text("SHARE WITH TEAMMATE").leafSectionLabel()
            .foregroundStyle(LeafColor.text.tertiary)
          Text("Send the link via Slack / iMessage / email, or read the code aloud.")
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.secondary)

          Text(token.code)
            .font(LeafType.mono.regular)
            .tracking(2)
            .foregroundStyle(LeafColor.text.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, LeafSpace.sm)

          HStack(spacing: LeafSpace.sm) {
            Spacer()
            LeafButton("Copy link", variant: .secondary, size: .sm) {
              copyToPasteboard(inviteURL(for: token).absoluteString)
            }
            LeafButton("Copy code", variant: .secondary, size: .sm) {
              copyToPasteboard(token.code)
            }
          }
        }
      }

      // Metadata card — countdown + max-uses + approval-required hint.
      LeafCard(variant: .glass, padding: .regular) {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
          if let expiresAt = token.expiresAt {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
              HStack(spacing: LeafSpace.xs) {
                Image(systemName: "clock")
                  .foregroundStyle(LeafColor.text.tertiary)
                Text(countdownText(expiresAt: expiresAt, now: ctx.date))
                  .font(LeafType.body.small)
                  .foregroundStyle(LeafColor.text.tertiary)
              }
            }
          } else {
            HStack(spacing: LeafSpace.xs) {
              Image(systemName: "infinity")
                .foregroundStyle(LeafColor.text.tertiary)
              Text("Never expires")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
            }
          }
          HStack(spacing: LeafSpace.xs) {
            Image(systemName: "arrow.triangle.2.circlepath")
              .foregroundStyle(LeafColor.text.tertiary)
            Text(usesText(used: token.usedCount, max: token.maxUses))
              .font(LeafType.body.small)
              .foregroundStyle(LeafColor.text.tertiary)
          }
          HStack(spacing: LeafSpace.xs) {
            Image(systemName: "lock.shield")
              .foregroundStyle(LeafColor.text.tertiary)
            Text("Anyone using this needs your approval")
              .font(LeafType.body.small)
              .foregroundStyle(LeafColor.text.tertiary)
          }
        }
      }
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      switch reader.state {
      case .idle, .loaded, .loading, .error:
        LeafButton("Cancel", variant: .secondary, size: .md) { dismiss() }
        Spacer()
        LeafButton("Generate", variant: .primary, size: .md) {
          let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
          reader.generate(
            label: trimmedLabel.isEmpty ? nil : trimmedLabel,
            ttlSeconds: ttl.seconds,
            singleUse: singleUse
          )
        }
      case .generating:
        LeafButton("Cancel", variant: .secondary, size: .md) { dismiss() }
          .disabled(true)
        Spacer()
        LeafButton("Generate", variant: .primary, size: .md, action: {})
          .disabled(true)
      case .ready:
        Spacer()
        LeafButton("Done", variant: .primary, size: .md) {
          reader.refresh()
          dismiss()
        }
      }
    }
  }

  // MARK: - Helpers

  private func inviteURL(for token: InviteToken) -> URL {
    URL(string: "leaf://invite/\(token.code)") ?? URL(string: "leaf://invite/UNKNOWN")!
  }

  private func copyToPasteboard(_ string: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(string, forType: .string)
  }

  private func countdownText(expiresAt: Date, now: Date) -> String {
    let remaining = max(0, expiresAt.timeIntervalSince(now))
    let total = Int(remaining)
    let d = total / 86400
    let h = (total % 86400) / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if d > 0 { return "Expires in \(d)d \(h)h" }
    if h > 0 { return "Expires in \(h)h \(m)m" }
    if m > 0 { return "Expires in \(m)m \(s)s" }
    return total > 0 ? "Expires in \(s)s" : "Expired"
  }

  private func usesText(used: Int, max: Int?) -> String {
    if let max = max {
      return "\(used) / \(max) uses"
    }
    return "\(used) / unlimited uses"
  }
}
