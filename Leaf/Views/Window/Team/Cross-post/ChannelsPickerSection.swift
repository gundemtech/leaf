//
//  ChannelsPickerSection.swift
//  Leaf
//
//  Track 5 / S6 T12 — Replaces the S4 "Coming in S6" channelsHint in
//  SendDirectMessageSheet with interactive cross-post controls.
//
//  Children:
//   - Locked Leaf row (always ON, disabled visually — DM always sends).
//   - SlackChannelRow (toggle + channel picker OR scope-missing banner).
//   - LinearTeamRow (toggle + team + assignee OR scope-missing banner).
//   - CrossPostPrivacyBanner — renders below the rows ONLY when any
//     non-Leaf toggle is ON. Per spec §6 trust invariant: prominent,
//     never tooltip-buried.
//
//  Environment readers (composition root injects at T13):
//   - SlackChannelsReader / LinearTeamsReader — cached lists.
//   - SlackScopesReader  / LinearScopesReader  — crossPostReady flag.
//   - LinearUsersResolverEnv — wrapper around LinearUsersResolver actor
//     so the SwiftUI view can call into the actor via a @Sendable
//     closure (actors can't be directly used as @Environment values).
//

import SwiftUI
import LeafCore

struct ChannelsPickerSection: View {
    @Environment(SlackChannelsReader.self) private var slackChannels
    @Environment(LinearTeamsReader.self) private var linearTeams

    @Binding var slackEnabled: Bool
    @Binding var slackChannelID: String?
    @Binding var linearEnabled: Bool
    @Binding var linearTeamID: String?
    @Binding var linearAssigneeID: String?
    @Binding var linearAssigneeNote: String?

    let kind: DirectMessageKind
    let recipientDisplayName: String

    /// Composition root supplies these closures so this view stays
    /// SwiftUI-pure (no actor dependencies, no OAuth services imported).
    let onReauthorizeSlack: @MainActor () async -> Void
    let resolveLinearAssignee: @MainActor (String) async -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("CHANNELS")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                leafRow
                SlackChannelRow(
                    enabled: $slackEnabled,
                    selectedChannelID: $slackChannelID,
                    onReauthorize: onReauthorizeSlack
                )
                LinearTeamRow(
                    enabled: $linearEnabled,
                    selectedTeamID: $linearTeamID,
                    selectedAssigneeID: $linearAssigneeID,
                    assigneeNote: $linearAssigneeNote,
                    kind: kind,
                    recipientDisplayName: recipientDisplayName,
                    resolveAssignee: resolveLinearAssignee
                )
            }

            if slackEnabled || linearEnabled {
                CrossPostPrivacyBanner()
            }
        }
        .task {
            await slackChannels.refreshIfStale()
            await linearTeams.refreshIfStale()
        }
    }

    @ViewBuilder
    private var leafRow: some View {
        HStack(alignment: .center, spacing: LeafSpace.md) {
            // Locked ON toggle — visually disabled but rendered ON so users
            // immediately understand the DM is the always-shipped E2E path.
            Toggle("", isOn: .constant(true))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(LeafColor.accent.primary)
                .disabled(true)
            Image(systemName: "lock.fill")
                .font(.system(size: 16))
                .foregroundStyle(LeafColor.status.success)
            Text("Leaf")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.primary)
            Text("End-to-end encrypted, always on.")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
            Spacer(minLength: 0)
        }
    }
}
