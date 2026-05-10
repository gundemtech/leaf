//
//  TeamView.swift
//  Track 2 / D3 — Team screen on D1 substrate. Adaptive grid (LazyVGrid with
//  GridItem(.adaptive(minimum: 240, maximum: 360))) of LeafCard members.
//  Empty state — gain-framed copy ("You're solo for now"). Error state —
//  LeafBanner.danger + retry. RemovedFromTeamBanner preempts via RootView.
//
//  Self-row hides overflow Menu (compare member.pubkeyHex против myPubHex
//  resolved from IdentityService.ensureLocalIdentity). 'Add member' CTA
//  переезжает в LeafSection cta-slot (top-right) — убирает floating
//  bottom button.
//

import CryptoKit
import SwiftUI
import LeafCore

struct TeamView: View {
    @Environment(OrgReader.self) private var reader
    @Environment(PendingInvitesReader.self) private var pendingReader
    @Environment(WindowState.self) private var windowState

    @State private var showingGenerateSheet: Bool = false
    @State private var pendingRemoval: PendingRemoval?
    @State private var myPubHex: String = ""

    private struct PendingRemoval: Identifiable {
        let id = UUID()
        let memberID: String
        let displayName: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xxl) {
                content
            }
            .padding(LeafSpace.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            reader.refresh()
            pendingReader.refresh()
            loadMyPubHex()
        }
        .sheet(isPresented: $showingGenerateSheet) {
            GenerateInviteSheet()
        }
        .sheet(item: $pendingRemoval) { removal in
            RemoveMemberSheet(memberID: removal.memberID, displayName: removal.displayName)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.top, LeafSpace.xxxl)

        case .empty:
            emptyContent

        case .loaded(_, let members):
            loadedContent(members)

        case .error(let message):
            errorContent(message)

        case .removedFromOrg:
            // RootView preempts via RemovedFromTeamBanner; defensive EmptyView
            // for switch exhaustiveness.
            EmptyView()
        }
    }

    // MARK: - Empty

    private var emptyContent: some View {
        LeafEmptyState(
            icon: LeafIcons.nav.team,
            title: "You're solo for now",
            description: "Create an org or accept an invite to start sharing presence with teammates.",
            ctaTitle: "Open Organization",
            onCTA: { windowState.section = .organization }
        )
    }

    // MARK: - Loaded

    private func loadedContent(_ members: [TeamMember]) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.xxl) {
            LeafSection(title: "Team · \(members.count) member\(members.count == 1 ? "" : "s")") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: LeafSpace.md)],
                    alignment: .leading,
                    spacing: LeafSpace.md
                ) {
                    ForEach(members, id: \.id) { member in
                        memberCard(member)
                    }
                }
            } cta: {
                addMemberButton
            }

            PendingInvitesSection()
        }
    }

    private var addMemberButton: some View {
        LeafButton(
            "Add member",
            variant: .primary,
            size: .sm,
            icon: .asset(LeafIcons.action.add),
            action: { showingGenerateSheet = true }
        )
    }

    private func memberCard(_ member: TeamMember) -> some View {
        LeafCard(variant: .raised, padding: .regular) {
            HStack(alignment: .center, spacing: LeafSpace.md) {
                LeafAvatar(initials: avatarInitials(member.displayName), size: .md)

                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    HStack(spacing: LeafSpace.sm) {
                        Text(member.displayName)
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.primary)
                            .lineLimit(1)
                        roleBadge(member.role)
                    }
                    Text(pubkeyShortHex(member.pubkeyHex))
                        .font(LeafType.mono.small)
                        .foregroundStyle(LeafColor.text.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if !myPubHex.isEmpty && member.pubkeyHex != myPubHex {
                    overflowMenu(member)
                }
            }
        }
    }

    private func overflowMenu(_ member: TeamMember) -> some View {
        Menu {
            Button("Remove from team…", role: .destructive) {
                pendingRemoval = PendingRemoval(
                    memberID: member.id,
                    displayName: member.displayName
                )
            }
        } label: {
            LeafIcon(
                systemName: "ellipsis",
                size: .md,
                tint: LeafColor.text.tertiary
            )
        }
        .menuStyle(.borderlessButton)
        .frame(width: LeafSpace.xxl)   // 32pt — taps space
    }

    private func roleBadge(_ role: TeamMemberRole) -> some View {
        let variant: LeafBadgeTokens.Variant = (role == .admin) ? .accent : .neutral
        return LeafBadge(text: role.rawValue.uppercased(), variant: variant)
    }

    // MARK: - Error

    private func errorContent(_ message: String) -> some View {
        LeafBanner(
            tone: .danger,
            title: "Couldn't load team",
            description: message,
            ctaTitle: "Try again",
            onCTA: { reader.refresh() }
        )
    }

    // MARK: - Helpers

    private func loadMyPubHex() {
        do {
            let priv = try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot())
            myPubHex = priv.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }.joined()
        } catch {
            myPubHex = ""
        }
    }

    private func avatarInitials(_ displayName: String) -> String {
        let parts = displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        return parts.isEmpty ? "?" : parts
    }

    private func pubkeyShortHex(_ hex: String) -> String {
        guard hex.count >= 16 else { return hex }
        return "\(hex.prefix(8))…\(hex.suffix(8))"
    }
}
