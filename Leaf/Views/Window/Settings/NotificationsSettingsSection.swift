//
//  NotificationsSettingsSection.swift
//  Track 5 / S8 / T9 — 4 sub-grouped toggles × 11 prefs per Track 5
//  contract §10.2. Binds to NotificationPrefsReader.
//
//  Sub-groups (top→bottom):
//    1. Direct messages — handoff (LOCKED ON) / task / ping
//    2. Auto-detected — decision / blocker / open question / where stopped
//    3. Raw activity — combined commit/Linear/Slack-mention switch
//    4. Behavior — respect macOS Focus / coalesce / sound
//
//  Locked-kind UX: `.handoff` row renders a small lock icon next to the
//  label + the Toggle is `.disabled(true)`. The lock invariant is enforced
//  defence-in-depth at NotificationPrefsStore.setEnabled (throws
//  `cannotDisableLockedKind` if a future code path still tries).
//
//  Each toggle write hits the writer Database (`setNotificationPref`) +
//  best-effort Supabase mirror (`upsertNotificationPref` — apns_push reads
//  the server row to skip pushes for disabled kinds).
//

import SwiftUI
import LeafCore

struct NotificationsSettingsSection: View {
    @Environment(NotificationPrefsReader.self) private var reader

    var body: some View {
        LeafSection(
            title: "Notifications",
            description: "Per-kind notification controls. Handoff is always on — receiving a teammate's handoff is the primitive that makes async work feasible. Everything else is opt-in."
        ) {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                subGroup(
                    title: "Direct messages",
                    description: "Pushes from teammates via the workspace direct-message channel.",
                    kinds: [.handoff, .task, .ping]
                )
                subGroup(
                    title: "Auto-detected",
                    description: "Pushes when Leaf detects something in your activity that another teammate may want to act on.",
                    kinds: [.decision, .blocker, .openQuestion, .whereStopped]
                )
                subGroup(
                    title: "Raw activity",
                    description: "Surfaces commit, Linear, and Slack mention events as pushes when posted by teammates.",
                    kinds: [.rawActivity]
                )
                subGroup(
                    title: "Behavior",
                    description: "How and when Leaf delivers the pushes you've opted into above.",
                    kinds: [.respectFocus, .coalesce, .sound]
                )
            }
        }
        .onAppear { reader.refresh() }
    }

    // MARK: - Sub-groups

    @ViewBuilder
    private func subGroup(
        title: String,
        description: String,
        kinds: [NotificationKind]
    ) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                Text(title)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                Text(description)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
            }
            VStack(spacing: LeafSpace.xs) {
                ForEach(kinds, id: \.self) { kind in
                    NotificationPrefRow(kind: kind)
                }
            }
        }
    }
}

private struct NotificationPrefRow: View {
    @Environment(NotificationPrefsReader.self) private var reader
    let kind: NotificationKind

    var body: some View {
        LeafCard(variant: .raised, padding: .regular) {
            HStack(alignment: .center, spacing: LeafSpace.md) {
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    HStack(spacing: LeafSpace.xs) {
                        Text(kind.displayLabel)
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.primary)
                        if kind.locked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(LeafColor.text.tertiary)
                                .help("Always on — receiving handoffs is the primitive that makes async work feasible.")
                        }
                    }
                }
                Spacer(minLength: 0)
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(LeafColor.accent.primary)
                    .disabled(kind.locked)
            }
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { reader.isEnabled(kind) },
            set: { newValue in
                Task { await reader.setEnabled(kind, enabled: newValue) }
            }
        )
    }
}
