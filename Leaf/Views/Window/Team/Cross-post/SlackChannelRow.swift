//
//  SlackChannelRow.swift
//  Leaf
//
//  Track 5 / S6 T12 — Slack row of ChannelsPickerSection. Three states:
//   1. Scope missing → inline re-auth banner (replaces channel picker).
//   2. Toggle OFF → just the toggle + provider label.
//   3. Toggle ON + scope present → toggle + channel dropdown.
//
//  Composition root wires `SlackChannelsReader` + `SlackScopesReader` +
//  a `LinearOAuthReauthorizing`-style closure for Slack re-auth (T13).
//

import SwiftUI
import LeafCore

struct SlackChannelRow: View {
    @Environment(SlackChannelsReader.self) private var channelsReader
    @Environment(SlackScopesReader.self) private var scopesReader

    @Binding var enabled: Bool
    @Binding var selectedChannelID: String?

    /// Composition root binds this to `SlackOAuthService.connect()` on T13;
    /// in dev (no LinearOAuthReauthorizing-equivalent for Slack landing
    /// today), the no-op closure leaves the inline banner showing "needs
    /// re-auth" copy — manual flow via Settings → Connections still works.
    let onReauthorize: @MainActor () async -> Void
    @State private var isReauthorizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            HStack(alignment: .center, spacing: LeafSpace.md) {
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(LeafColor.accent.primary)
                    .disabled(!scopesReader.crossPostReady)
                Image(systemName: "number.square")
                    .font(.system(size: 16))
                    .foregroundStyle(LeafColor.text.secondary)
                Text("Slack")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                Spacer(minLength: 0)
                if enabled && scopesReader.crossPostReady {
                    channelPicker
                }
            }
            if enabled && !scopesReader.crossPostReady {
                scopeMissingBanner
            }
            if enabled && scopesReader.crossPostReady && channelsReader.channels.isEmpty {
                Text("No channels found. Reconnect Slack if you expected to see channels here.")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        }
        .onChange(of: enabled) { _, isOn in
            if !isOn { selectedChannelID = nil }
        }
    }

    @ViewBuilder
    private var channelPicker: some View {
        Picker("Channel", selection: Binding(
            get: { selectedChannelID ?? channelsReader.channels.first?.id ?? "" },
            set: { selectedChannelID = $0.isEmpty ? nil : $0 }
        )) {
            if channelsReader.channels.isEmpty {
                Text("No channels").tag("")
            } else {
                ForEach(channelsReader.channels) { channel in
                    Text("#\(channel.name)").tag(channel.id)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 200, alignment: .trailing)
    }

    @ViewBuilder
    private var scopeMissingBanner: some View {
        LeafCard(variant: .raised, padding: .regular) {
            HStack(alignment: .top, spacing: LeafSpace.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LeafColor.status.warning)
                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    Text("Slack: requires re-auth to send messages")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.primary)
                    LeafButton(
                        isReauthorizing ? "Re-authorizing…" : "Re-authorize Slack",
                        variant: .secondary,
                        size: .sm,
                        action: { Task { await runReauth() } }
                    )
                    .disabled(isReauthorizing)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @MainActor
    private func runReauth() async {
        guard !isReauthorizing else { return }
        isReauthorizing = true
        defer { isReauthorizing = false }
        await onReauthorize()
        await scopesReader.refresh()
        // Warm channel cache so the picker appears immediately on next
        // toggle ON without a spinner.
        await channelsReader.refreshOnConnect()
    }
}
