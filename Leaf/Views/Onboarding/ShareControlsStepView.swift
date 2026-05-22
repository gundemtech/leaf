//
//  ShareControlsStepView.swift
//  Track-10 T1 / C5 — onboarding `.shareControls` step. Pre-populates the
//  `LocalAppsStore` whitelist from a moat-resident preset of common dev app
//  bundle IDs (`OnboardingShareTemplateFactory.current.defaultTemplate()`).
//  Per-row toggle lets the user opt out before accepting. "Accept all"
//  writes the (possibly modified) selection into `LocalAppsStore`; "Skip"
//  advances without writes, leaving the store at its default-OFF baseline.
//
//  Public clones (no LeafCorePrivate moat) see an empty entries list —
//  panel renders a compact informational fallback + Continue button.
//

import LeafCore
import SwiftUI

struct ShareControlsStepView: View {
    @Environment(PermissionsService.self) private var permissions

    /// Snapshot at view init — captures whatever the moat registered at app
    /// launch. Per-row toggle state lives in `enabled` keyed by bundleID.
    @State private var entries: [BundleAppEntry] = OnboardingShareTemplateFactory.current.defaultTemplate()
    @State private var enabled: [String: Bool] = [:]

    let onAdvance: () -> Void

    var body: some View {
        if entries.isEmpty {
            emptyState
        } else {
            populated
        }
    }

    // MARK: - Empty fallback (public clone or moat unregistered)

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("Share controls")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text(
                "Share controls will be configured later in Settings → Local Apps. You can pick what your team sees per app."
            )
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                LeafButton("Continue", variant: .primary, size: .sm, action: onAdvance)
            }
        }
    }

    // MARK: - Populated panel

    private var populated: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("Share with team")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text("We pre-selected common dev apps. Tap to deselect any you don't want shared.")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // ~14 entries don't fit the 320pt-wide popover budget without
            // scrolling. maxHeight: 220 leaves room for title + description
            // + CTA pair under the popover's typical ~400pt cap.
            ScrollView {
                LazyVStack(spacing: LeafSpace.xs) {
                    ForEach(entries, id: \.bundleID) { entry in
                        appRow(entry)
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack {
                LeafButton("Skip", variant: .ghost, size: .sm, action: onAdvance)
                Spacer()
                LeafButton("Accept all", variant: .primary, size: .sm, action: acceptAll)
            }
        }
        .onAppear {
            // Seed per-row toggle state from preset defaults on first appear.
            // Re-appear (back-navigation, currently unused) preserves user edits.
            if enabled.isEmpty {
                for entry in entries {
                    enabled[entry.bundleID] = entry.defaultEnabled
                }
            }
        }
    }

    @ViewBuilder
    private func appRow(_ entry: BundleAppEntry) -> some View {
        let isOn = Binding<Bool>(
            get: { enabled[entry.bundleID] ?? entry.defaultEnabled },
            set: { enabled[entry.bundleID] = $0 }
        )
        HStack(spacing: LeafSpace.sm) {
            Text(entry.displayName)
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.primary)
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(LeafColor.accent.primary)
        }
        .padding(.horizontal, LeafSpace.xs)
        .padding(.vertical, LeafSpace.xxs)
        // VoiceOver: combine the row into a single composed element so the
        // app name isn't spoken twice (once as the Text, once as the Toggle
        // label). Reads as "<appName>, switch button, on/off" (a11y I1).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.displayName)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }

    private func acceptAll() {
        // 14 sequential setEnabled calls → 14 main-queue objectWillChange hops
        // (LocalAppsStore lines 65-67). Acceptable one-time onboarding cost;
        // batch-set API tracked in Track-9 §9.1 C-5 reactivity refactor.
        for entry in entries {
            let on = enabled[entry.bundleID] ?? entry.defaultEnabled
            permissions.localAppsStore.setEnabled(entry.bundleID, on)
        }
        onAdvance()
    }
}
