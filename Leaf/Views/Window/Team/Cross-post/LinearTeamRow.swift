//
//  LinearTeamRow.swift
//  Leaf
//
//  Track 5 / S6 T12 — Linear row of ChannelsPickerSection. States:
//   - Toggle disabled when DM kind != .task (Handoff/Ping ineligible for
//     issue creation — Linear cross-post creates an Issue, which only
//     maps to Task kind).
//   - Scope missing → re-auth banner (replaces team + assignee pickers).
//   - Toggle ON: team picker (required) + assignee picker (optional).
//   - When LinearUsersResolver returns nil for the recipient's display
//     name → inline notice "Will create unassigned issue…" (A4 fallback).
//
//  Composition root (T13) wires the LinearOAuthReauthorizing protocol; we
//  consume LinearScopesReader for the synchronous `crossPostReady` flag
//  and its `reauthorize()` coroutine.
//

import SwiftUI
import LeafCore

struct LinearTeamRow: View {
    @Environment(LinearTeamsReader.self) private var teamsReader
    @Environment(LinearScopesReader.self) private var scopesReader

    @Binding var enabled: Bool
    @Binding var selectedTeamID: String?
    @Binding var selectedAssigneeID: String?
    @Binding var assigneeNote: String?

    /// Kind chosen in the kindPicker. Linear cross-post only allowed on .task.
    let kind: DirectMessageKind
    let recipientDisplayName: String
    let resolveAssignee: @MainActor (String) async -> String?

    @State private var isResolving = false

    private var isKindEligible: Bool { kind == .task }

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            HStack(alignment: .center, spacing: LeafSpace.md) {
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(LeafColor.accent.primary)
                    .disabled(!isKindEligible || !scopesReader.crossPostReady)
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 16))
                    .foregroundStyle(LeafColor.text.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Linear (Task only)")
                        .font(LeafType.body.regular)
                        .foregroundStyle(
                            isKindEligible ? LeafColor.text.primary : LeafColor.text.tertiary
                        )
                    if !isKindEligible {
                        Text("Available for Task kind. Switch type to Task to enable.")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }

            if enabled && isKindEligible && scopesReader.crossPostReady {
                HStack(spacing: LeafSpace.sm) {
                    teamPicker
                    assigneePicker
                }
                if let note = assigneeNote, !note.isEmpty {
                    Text("⚠ \(note)")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.status.warning)
                }
            }

            if enabled && isKindEligible && !scopesReader.crossPostReady {
                scopeMissingBanner
            }
        }
        .onChange(of: kind) { _, newKind in
            if newKind != .task { enabled = false }
        }
        .onChange(of: enabled) { _, isOn in
            if !isOn {
                selectedTeamID = nil
                selectedAssigneeID = nil
                assigneeNote = nil
                return
            }
            // Fire-and-forget assignee resolution once toggle flips on.
            Task { await resolveAssigneeForRecipient() }
        }
    }

    @ViewBuilder
    private var teamPicker: some View {
        Picker("Team", selection: Binding(
            get: { selectedTeamID ?? teamsReader.teams.first?.id ?? "" },
            set: { selectedTeamID = $0.isEmpty ? nil : $0 }
        )) {
            if teamsReader.teams.isEmpty {
                Text("No teams").tag("")
            } else {
                ForEach(teamsReader.teams) { team in
                    Text("\(team.name) — \(team.key)").tag(team.id)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 200, alignment: .trailing)
    }

    @ViewBuilder
    private var assigneePicker: some View {
        // Future-extensible — for now we show "Assign: <name>" or "Unassigned".
        // T9 LinearUsersResolver returns a single best match for recipient's
        // display name; no list-picker UI in S6 (A4 carry-over M14).
        HStack(spacing: LeafSpace.xs) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(LeafColor.text.tertiary)
            Text(assigneeLabel)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }

    private var assigneeLabel: String {
        if isResolving { return "Resolving assignee…" }
        if selectedAssigneeID != nil { return "Assign: \(recipientDisplayName)" }
        return "Unassigned"
    }

    @ViewBuilder
    private var scopeMissingBanner: some View {
        LeafCard(variant: .raised, padding: .regular) {
            HStack(alignment: .top, spacing: LeafSpace.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LeafColor.status.warning)
                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    Text("Linear: requires re-auth to create issues")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.primary)
                    LeafButton(
                        scopesReader.isReauthorizing ? "Re-authorizing…" : "Re-authorize Linear",
                        variant: .secondary,
                        size: .sm,
                        action: { Task { await scopesReader.reauthorize() } }
                    )
                    .disabled(scopesReader.isReauthorizing)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @MainActor
    private func resolveAssigneeForRecipient() async {
        guard !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        let resolved = await resolveAssignee(recipientDisplayName)
        if let resolved {
            selectedAssigneeID = resolved
            assigneeNote = nil
        } else {
            selectedAssigneeID = nil
            assigneeNote = "Will create unassigned issue (couldn't find ‘\(recipientDisplayName)’ in Linear)"
        }
    }
}
