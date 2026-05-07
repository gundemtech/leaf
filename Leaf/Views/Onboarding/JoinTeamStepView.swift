//
//  JoinTeamStepView.swift
//  Leaf
//
//  Phase 5.5.B — onboarding `.team` invitee path. Step 1: display name + Join code share.
//  JoinCode encoded із IdentityService.ensureLocalIdentity().publicKey on appear; cached в
//  @State так что повторные refresh'ы не re-derive. Embedded в pre-filled "inviteeShare" template
//  (ShareTemplate.compose(.inviteeShare(displayName:, joinCode:))) → ShareTemplateButton отдаёт
//  Copy / Mail / Messages.
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Join existing team")
                .font(.subheadline.weight(.semibold))
            Text("Pick a name your team will see, then send your Join code to whoever invited you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR DISPLAY NAME")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. Anton", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR JOIN CODE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if joinCode.isEmpty {
                    Text(loadError ?? "Generating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(joinCode)
                        .font(.system(.caption, design: .monospaced))
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
                Button("Back") { onCancel() }
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
                Button("I shared it — wait for invite") {
                    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    acceptReader.saveInviteeDisplayName(trimmed)
                    onAdvance()
                }
                .buttonStyle(.borderedProminent)
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
            // Hex → 32 bytes → JoinCode.encode.
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
