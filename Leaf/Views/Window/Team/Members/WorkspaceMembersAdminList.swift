//
//  WorkspaceMembersAdminList.swift
//  Track 5 / S7 — F.4. Member list card; lives on the Team hub's Members
//  tab (relocated from Settings → Workspace). Resolves viewer identity
//  pubkey on appear (same pattern as TeamView) to determine viewerIsAdmin
//  and hide the ellipsis on self-rows. Roster ordering + admin detection
//  via WorkspaceHubPresentation (LeafCore). Tapping a non-self row opens
//  the DM composer through `onTapMember`.
//

import CryptoKit
import SwiftUI
import LeafCore

struct WorkspaceMembersAdminList: View {
    @Environment(WorkspaceReader.self) private var workspaceReader
    @State private var myPubHex: String = ""

    /// Non-self row tap → DM composer (hub Members tab). Nil = rows inert.
    var onTapMember: ((TeamMember) -> Void)? = nil

    var body: some View {
        if case .loaded(_, _, let members) = workspaceReader.state {
            LeafCard(variant: .raised, padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    Text("MEMBERS")
                        .leafSectionLabel()
                        .foregroundStyle(LeafColor.text.tertiary)

                    let viewerIsAdmin = WorkspaceHubPresentation.isViewerAdmin(
                        pubkeyHex: myPubHex, members: members)
                    let roster = WorkspaceHubPresentation.sortedRoster(members)

                    ForEach(roster, id: \.id) { member in
                        WorkspaceMemberAdminRow(
                            member: member,
                            isMe: member.pubkeyHex == myPubHex,
                            viewerIsAdmin: viewerIsAdmin,
                            onTap: member.pubkeyHex == myPubHex
                                ? nil
                                : onTapMember.map { tap in { tap(member) } }
                        )

                        if member.id != roster.last?.id {
                            LeafDivider(style: .soft)
                        }
                    }
                }
            }
            .onAppear { loadMyPubHex() }
        }
    }

    // MARK: - Identity

    private func loadMyPubHex() {
        guard myPubHex.isEmpty else { return }
        do {
            let priv = try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot())
            myPubHex = priv.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }.joined()
        } catch {
            myPubHex = ""
        }
    }
}
