//
//  WorkspaceMembersAdminList.swift
//  Track 5 / S7 — F.4. Member list card inside WorkspaceSettingsSection.
//  Resolves viewer identity pubkey on appear (same pattern as TeamView) to
//  determine viewerIsAdmin and hide the ellipsis on self-rows.
//  Admin ellipsis → confirmationDialog → Phase H wires actual removal.
//

import CryptoKit
import SwiftUI
import LeafCore

struct WorkspaceMembersAdminList: View {
    @Environment(WorkspaceReader.self) private var workspaceReader
    @State private var myPubHex: String = ""

    var body: some View {
        if case .loaded(_, _, let members) = workspaceReader.state {
            LeafCard(variant: .raised, padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    Text("MEMBERS")
                        .leafSectionLabel()
                        .foregroundStyle(LeafColor.text.tertiary)

                    let viewerIsAdmin = members.contains {
                        $0.pubkeyHex == myPubHex && $0.role == .admin
                    }

                    ForEach(members, id: \.id) { member in
                        WorkspaceMemberAdminRow(
                            member: member,
                            isMe: member.pubkeyHex == myPubHex,
                            viewerIsAdmin: viewerIsAdmin
                        )

                        if member.id != members.last?.id {
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
