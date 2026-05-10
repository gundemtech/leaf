//
//  JoinTeamStepView.swift
//  Leaf
//
//  Phase 5.5.B — onboarding `.team` invitee path. Step 1: display name + Join code share.
//  Track 2 / D4 — migrated to D1 atoms.
//

import SwiftUI
import AppKit
import LeafCore

struct JoinTeamStepView: View {
    @Environment(InviteAcceptReader.self) private var acceptReader
    @State private var displayName: String = ""
    @State private var joinCode: String = ""
    @State private var loadError: String? = nil
    let onAdvance: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("Join existing team")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text("Pick a name your team will see, then send your Join code to whoever invited you.")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text("YOUR DISPLAY NAME").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                TextField("e.g. Sasha", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .font(LeafType.body.regular)
            }

            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text("YOUR JOIN CODE").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                if joinCode.isEmpty {
                    Text(loadError ?? "Generating…")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                } else {
                    Text(joinCode)
                        .font(LeafType.mono.small)
                        .foregroundStyle(LeafColor.text.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            if !joinCode.isEmpty && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ShareTemplateButton(
                    templateBody: ShareTemplate.compose(.inviteeShare(
                        displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                        joinCode: joinCode
                    )),
                    mailSubject: "Leaf invite — Join code"
                )
            }

            HStack {
                LeafButton("Back", variant: .ghost, size: .sm, action: onCancel)
                Spacer()
                LeafButton(
                    "I shared it — wait for invite",
                    variant: .primary,
                    size: .sm,
                    action: {
                        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        acceptReader.saveInviteeDisplayName(trimmed)
                        onAdvance()
                    }
                )
                .disabled(joinCode.isEmpty || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            if displayName.isEmpty { displayName = NSFullUserName() }
            loadJoinCode()
        }
    }

    private func loadJoinCode() {
        do {
            let hex = try acceptReader.myPubkeyHex()
            var bytes = Data(capacity: 32)
            var idx = hex.startIndex
            while idx < hex.endIndex {
                let next = hex.index(idx, offsetBy: 2)
                if let b = UInt8(hex[idx..<next], radix: 16) { bytes.append(b) }
                idx = next
            }
            joinCode = try JoinCode.encode(pubkey: bytes)
        } catch {
            loadError = "Couldn't generate Join code. Try restarting the app."
        }
    }
}
