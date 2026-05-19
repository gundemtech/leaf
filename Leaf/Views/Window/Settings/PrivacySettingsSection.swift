//
//  PrivacySettingsSection.swift
//  Track 5 / S8 / T10 — closes contract §13:479 + S5 §6 deferred-to-S8.
//
//  Expands the Track-2 / D4 stub into two cards:
//    1. «Keep auto-shared events for» picker — 30/60/90/180/365 days,
//       binds to `MirrorRetentionConfig` UserDefaults (read by
//       `TeamEventMirrorRetentionPruner` via injected closure).
//    2. «Never shared» read-only deny-list — 4 reasons surfaced from
//       `DefaultDenyList.userVisibleReasons` (canonical user-facing copy
//       sourced from LeafCore so future denylist changes propagate via
//       a single property update).
//
//  Direct messages are deliberately NOT subject to the picker — they're
//  retained forever per Track 5 privacy contract (separate retention
//  path; surfaced as caption text under the picker for clarity).
//

import SwiftUI
import LeafCore

struct PrivacySettingsSection: View {

    @State private var retentionDays: Int = MirrorRetentionConfig.retentionDays()

    var body: some View {
        LeafSection(
            title: "Privacy",
            description: "Controls how long auto-shared events from teammates stay on this device, and reminds you what is never transmitted regardless of share toggles."
        ) {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                retentionCard
                neverSharedCard
            }
        }
    }

    // MARK: - Retention picker

    private var retentionCard: some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                HStack(alignment: .center, spacing: LeafSpace.md) {
                    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                        Text("Keep auto-shared events for")
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.primary)
                        Text("Older mirror rows are pruned once per day. Lowering the value triggers prune on the next daily tick.")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.secondary)
                    }
                    Spacer(minLength: 0)
                    retentionMenu
                }
                Text("Direct messages are kept forever per privacy contract.")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        }
    }

    /// Compact Leaf-tokenized Menu (matches `FoldersSettings.granularityMenu`
    /// pattern — default macOS Picker chrome reads foreign on Leaf canvas).
    private var retentionMenu: some View {
        Menu {
            ForEach(MirrorRetentionConfig.allowedValues, id: \.self) { days in
                Button("\(days) days") {
                    retentionDays = days
                    MirrorRetentionConfig.setRetentionDays(days)
                }
            }
        } label: {
            HStack(spacing: LeafSpace.xs) {
                Text("\(retentionDays) days")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LeafColor.text.tertiary)
            }
            .padding(.horizontal, LeafSpace.sm)
            .padding(.vertical, LeafSpace.xs)
            .background(
                RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                    .fill(LeafColor.surface.inset)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Never shared

    private var neverSharedCard: some View {
        LeafCard(variant: .glass, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                HStack(spacing: LeafSpace.xs) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(LeafColor.text.secondary)
                    Text("Never shared")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                }
                Text("Regardless of any toggle, the following categories never leave this device:")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                ForEach(DefaultDenyList.userVisibleReasons, id: \.self) { reason in
                    HStack(alignment: .firstTextBaseline, spacing: LeafSpace.xs) {
                        Text("•")
                            .foregroundStyle(LeafColor.text.tertiary)
                        Text(reason)
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.primary)
                    }
                }
            }
        }
    }
}
