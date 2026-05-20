//
//  ActiveTokensSection.swift
//  Leaf
//
//  M027 invite-redesign — Settings → Workspace section listing active invite
//  tokens. Per-row [Copy link] [Copy code] [✕ Delete] + bulk Delete-all CTA.
//  Reads `InviteTokensReader.state.loaded(active:)` for the visible list;
//  empty active state hides the section entirely (Active = at most 10 rows).
//

import SwiftUI
import AppKit
import LeafCore

struct ActiveTokensSection: View {
    @Environment(InviteTokensReader.self) private var reader

    @State private var generateInvitePresented = false
    @State private var deleteCandidateCode: String?

    var body: some View {
        LeafSection(
            title: "Active invite tokens",
            description: "Workspace-scoped tokens admins can share via link or code. Anyone using a token needs your approval."
        ) {
            VStack(spacing: LeafSpace.md) {
                contentView
                actionsRow
            }
        }
        .onAppear { reader.refresh() }
        .sheet(isPresented: $generateInvitePresented) {
            GenerateInviteSheet()
        }
        .alert(
            "Delete this invite?",
            isPresented: Binding(
                get: { deleteCandidateCode != nil },
                set: { newValue in if !newValue { deleteCandidateCode = nil } }
            ),
            actions: {
                Button("Cancel", role: .cancel) { deleteCandidateCode = nil }
                Button("Delete", role: .destructive) {
                    if let code = deleteCandidateCode {
                        reader.delete(code: code)
                        deleteCandidateCode = nil
                    }
                }
            },
            message: {
                Text("Anyone trying to use this token will see «This invite no longer exists». Existing pending requests remain in your queue.")
            }
        )
    }

    @ViewBuilder
    private var contentView: some View {
        switch reader.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, LeafSpace.md)
        case .loaded(let active):
            if active.isEmpty {
                emptyState
            } else {
                tokensList(active)
            }
        case .generating:
            HStack { Spacer(); ProgressView("Generating…"); Spacer() }
                .padding(.vertical, LeafSpace.md)
        case .ready:
            // Transitional — sheet shows the new token; section will refresh on dismiss.
            tokensList([])
        case .error(let message):
            LeafBanner(tone: .danger, title: "Couldn't load active tokens", description: message)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: LeafSpace.sm) {
            Image(systemName: "ticket")
                .font(.system(size: 32))
                .foregroundStyle(LeafColor.text.tertiary)
            Text("No active invite tokens.")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
            Text("Generate one to invite teammates.")
                .font(LeafType.caption)
                .foregroundStyle(LeafColor.text.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LeafSpace.lg)
    }

    @ViewBuilder
    private func tokensList(_ tokens: [InviteToken]) -> some View {
        VStack(spacing: LeafSpace.sm) {
            ForEach(tokens, id: \.code) { token in
                tokenRow(token)
            }
        }
    }

    @ViewBuilder
    private func tokenRow(_ token: InviteToken) -> some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                HStack {
                    Text(token.displayLabel)
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                    Spacer()
                    Button {
                        deleteCandidateCode = token.code
                    } label: {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(LeafColor.status.danger)
                    }
                    .buttonStyle(.plain)
                    .help("Delete invite token")
                }

                Text("Code: \(token.code)")
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.secondary)
                    .textSelection(.enabled)

                HStack(spacing: LeafSpace.md) {
                    if let expiresAt = token.expiresAt {
                        TimelineView(.periodic(from: .now, by: 60)) { ctx in
                            metadataLabel(
                                icon: "clock",
                                text: countdownText(expiresAt: expiresAt, now: ctx.date)
                            )
                        }
                    } else {
                        metadataLabel(icon: "infinity", text: "Never expires")
                    }
                    metadataLabel(
                        icon: "arrow.triangle.2.circlepath",
                        text: usesText(used: token.usedCount, max: token.maxUses)
                    )
                }

                HStack(spacing: LeafSpace.sm) {
                    LeafButton("Copy link", variant: .secondary, size: .sm) {
                        copyToPasteboard("leaf://invite/\(token.code)")
                    }
                    LeafButton("Copy code", variant: .secondary, size: .sm) {
                        copyToPasteboard(token.code)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metadataLabel(icon: String, text: String) -> some View {
        HStack(spacing: LeafSpace.xs) {
            Image(systemName: icon)
                .foregroundStyle(LeafColor.text.tertiary)
                .font(LeafType.caption)
            Text(text)
                .font(LeafType.caption)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    @ViewBuilder
    private var actionsRow: some View {
        HStack {
            LeafButton("+ Generate new", variant: .primary, size: .md) {
                generateInvitePresented = true
            }
            Spacer()
        }
    }

    // MARK: - Helpers

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
        if d > 0 { return "Expires in \(d)d \(h)h" }
        if h > 0 { return "Expires in \(h)h \(m)m" }
        return "Expires in \(m)m"
    }

    private func usesText(used: Int, max: Int?) -> String {
        if let max = max {
            return "\(used) / \(max)"
        }
        return "\(used) / unlimited"
    }
}
