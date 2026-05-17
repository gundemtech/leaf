//
//  AIToolsSettingsSection.swift
//  Track-6 P1 Phase F — Settings → AI Tools section. Currently 1 row
//  (Claude Code) with master toggle (drives ~/.claude/settings.json hook
//  install via AIToolsHookInstaller), token sub-toggle (gates
//  claude_tokens_used jsonl emission), and "Why this is safe" disclosure.
//
//  Future Cursor / Continue.dev rows land here as additional rows when
//  those collectors ship.
//

import LeafCore
import SwiftUI

struct AIToolsSettingsSection: View {
    @Environment(PermissionsService.self) private var permissions

    var body: some View {
        LeafSection(
            title: "AI Tools",
            description:
                "Capture metadata from your AI coding sessions. Tool inputs, prompts, responses — never captured. Default OFF until you opt in."
        ) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                ClaudeCodeAIRow(permissions: permissions)
            }
        }
    }
}

private struct ClaudeCodeAIRow: View {
    let permissions: PermissionsService
    @State private var isEnabled: Bool = false
    @State private var tokensEnabled: Bool = false
    @State private var showWhyExpanded: Bool = false
    @State private var installer = AIToolsHookInstaller()

    var body: some View {
        LeafCard(variant: .raised, padding: .regular, header: { EmptyView() }) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                // Header row: icon + name + master toggle.
                HStack(alignment: .center, spacing: LeafSpace.md) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18))
                        .foregroundStyle(LeafColor.text.secondary)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                        Text("Claude Code")
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.primary)
                        Text("Inserts a hooks block in ~/.claude/settings.json and listens on a local socket.")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.secondary)
                    }
                    Spacer(minLength: 0)
                    statusBadge
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { isEnabled },
                            set: { newValue in
                                isEnabled = newValue
                                permissions.aiToolsStore.setEnabled("claude_code", newValue)
                                Task { await toggleHooks(enabled: newValue) }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(LeafColor.accent.primary)
                }

                // Token sub-toggle (disabled until master is ON).
                Toggle(
                    isOn: Binding(
                        get: { tokensEnabled },
                        set: { newValue in
                            tokensEnabled = newValue
                            permissions.aiToolsStore.setEnabled("claude_code.tokens", newValue)
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                        Text("Token attribution")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.primary)
                        Text("Records per-turn token counts (jsonl path). For your usage rollups in Derived Insights.")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.secondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(LeafColor.accent.primary)
                .disabled(!isEnabled)

                // "Why this is safe" disclosure — 4 bullets per spec §7.1.
                DisclosureGroup(isExpanded: $showWhyExpanded) {
                    VStack(alignment: .leading, spacing: LeafSpace.xs) {
                        bullet("Inserts a `hooks` block into `~/.claude/settings.json`.")
                        bullet("Hook bridge runs locally and writes to a local Unix socket.")
                        bullet("Prompt content / tool inputs / outputs / thinking — never read.")
                        bullet("Uninstall via this toggle removes only Leaf entries.")
                    }
                    .padding(.top, LeafSpace.xs)
                } label: {
                    Text("Why this is safe")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }
            }
        } footer: {
            EmptyView()
        }
        .onAppear {
            isEnabled = permissions.aiToolsStore.isEnabled("claude_code")
            tokensEnabled = permissions.aiToolsStore.isEnabled("claude_code.tokens")
        }
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: LeafSpace.xs) {
            Text("•")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
            Text(text)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch permissions.aiToolsStore.lastInstallResult {
        case .notAttempted:
            badgeView(text: "Not installed", color: LeafColor.text.tertiary)
        case .ok:
            badgeView(text: "Installed", color: LeafColor.status.success)
        case .failed(let msg):
            badgeView(text: "Failed: \(msg)", color: LeafColor.status.danger)
        }
    }

    @ViewBuilder
    private func badgeView(text: String, color: Color) -> some View {
        HStack(spacing: LeafSpace.xs) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }

    private func toggleHooks(enabled: Bool) async {
        do {
            let result = enabled ? try installer.install() : try installer.uninstall()
            await MainActor.run {
                switch result {
                case .ok:
                    // After uninstall returning .ok, badge should reset to "Not installed".
                    permissions.aiToolsStore.lastInstallResult = enabled ? .ok : .notAttempted
                case .partial(let msg), .failed(let msg):
                    permissions.aiToolsStore.lastInstallResult = .failed(msg)
                }
            }
        } catch {
            await MainActor.run {
                permissions.aiToolsStore.lastInstallResult = .failed("\(error.localizedDescription)")
            }
        }
    }
}
