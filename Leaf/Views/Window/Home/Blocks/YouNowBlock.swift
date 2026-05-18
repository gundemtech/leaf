//
//  YouNowBlock.swift
//  Track-8 / Phase 8.4 — Home YOU·NOW dashboard cell. 4 states surfaced via
//  `DerivedInsights.youNowState(now:)`: active / inMeeting / deepWorkFocus /
//  away. Substrate resolves priority (inMeeting > deepWorkFocus >
//  away(.screenLocked) > away(.idle) > active > away(degenerate)) so this
//  view is a pure switch renderer.
//
//  Resume CTA on .away fires only when 4 AND-conditions hold:
//  bundleID known + bundleID in LocalAppsStore.enabled + linearID known +
//  idleSec ≤ 24h. Otherwise the .away render shows base info without CTA.
//

import AppKit
import LeafCore
import SwiftUI

struct YouNowBlock: View {
    let state: YouNowState
    @StateObject private var localAppsStore = LocalAppsStore()

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("YOU · NOW")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                cardContent
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: state)
            }
            .contentShape(Rectangle())
            .onTapGesture { handleTap() }
        }
    }

    // MARK: - State dispatch

    @ViewBuilder
    private var cardContent: some View {
        switch state {
        case .active(let s):        activeContent(s)
        case .inMeeting(let m):     meetingContent(m)
        case .deepWorkFocus(let f): focusContent(f)
        case .away(let a):          awayContent(a)
        }
    }

    @ViewBuilder
    private func activeContent(_ s: YouNowActive) -> some View {
        rowLayout(
            iconAsset: "play.circle.fill",
            tint: LeafColor.accent.primary,
            title: s.app,
            titleTint: LeafColor.accent.primary,
            line2: [s.contextLabel, s.branch, s.linearID].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
            line3: formatDuration(TimeInterval(s.durationSec)),
            trailingBars: s.intensityBars
        )
    }

    @ViewBuilder
    private func meetingContent(_ m: YouNowMeeting) -> some View {
        rowLayout(
            iconAsset: "video.fill",
            tint: LeafColor.status.info,
            title: m.titleIfAvailable ?? "In a meeting",
            titleTint: LeafColor.status.info,
            line2: "Started \(formatRelative(msAgo: m.startedAtMs))",
            line3: m.endsAtMsIfAvailable.map { "Ends \(formatRelative(msAgo: $0))" },
            trailingBars: 0
        )
    }

    @ViewBuilder
    private func focusContent(_ f: YouNowFocus) -> some View {
        rowLayout(
            iconAsset: "moon.fill",
            tint: LeafColor.status.warning,
            title: "Deep work: \(f.modeName ?? "Focus")",
            titleTint: LeafColor.status.warning,
            line2: [f.app, f.contextLabel].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
            line3: formatDuration(TimeInterval(f.durationSec)),
            trailingBars: 0
        )
    }

    @ViewBuilder
    private func awayContent(_ a: YouNowAway) -> some View {
        let (icon, titleText, timeFooter) = awayPresentation(for: a)
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            rowLayout(
                iconAsset: icon,
                tint: LeafColor.text.tertiary,
                title: titleText,
                titleTint: LeafColor.text.secondary,
                line2: [a.lastApp.map { "Last in \($0)" }, a.lastContextLabel]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                    .nilIfEmpty,
                line3: timeFooter,
                trailingBars: 0
            )
            if shouldShowResume(a) {
                resumeCTA(for: a)
            }
        }
    }

    private func awayPresentation(for a: YouNowAway) -> (icon: String, title: String, footer: String) {
        switch a.reason {
        case .screenLocked:
            return ("lock.fill", "Screen locked", "locked \(formatDuration(TimeInterval(a.idleSec))) ago")
        case .idle:
            return ("moon.zzz.fill", "Idle", "idle \(formatDuration(TimeInterval(a.idleSec)))")
        case .sleep:
            return ("powersleep", "Asleep", "slept \(formatDuration(TimeInterval(a.idleSec))) ago")
        }
    }

    // MARK: - Shared row layout

    @ViewBuilder
    private func rowLayout(
        iconAsset: String,
        tint: Color,
        title: String,
        titleTint: Color,
        line2: String?,
        line3: String?,
        trailingBars: Int
    ) -> some View {
        HStack(alignment: .top, spacing: LeafSpace.md) {
            LeafIconChip(asset: iconAsset, size: .md, tint: tint)
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text(title)
                    .font(LeafType.title.small)
                    .foregroundStyle(titleTint)
                if let line2 {
                    Text(line2)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let line3 {
                    HStack(spacing: LeafSpace.xs) {
                        Text(line3)
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                        if trailingBars > 0 {
                            intensityBarsView(count: trailingBars)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func intensityBarsView(count: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(LeafColor.accent.primary)
                    .frame(width: 3, height: 8)
                    .opacity(i < count ? 1.0 : 0.25)
            }
        }
        .accessibilityLabel("Intensity \(count) of 4")
    }

    // MARK: - Resume CTA

    private func shouldShowResume(_ a: YouNowAway) -> Bool {
        guard let bundleID = a.lastAppBundleID, !bundleID.isEmpty,
              a.lastLinearID != nil,
              a.idleSec <= 86_400
        else { return false }
        return localAppsStore.isEnabled(bundleID)
    }

    @ViewBuilder
    private func resumeCTA(for a: YouNowAway) -> some View {
        let appLabel = a.lastApp ?? "app"
        let issue = a.lastLinearID ?? "task"
        Button {
            triggerResume(for: a)
        } label: {
            Text("→ Resume on \(issue) in \(appLabel)")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.accent.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume work on \(issue) in \(appLabel)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Tap handling

    private func handleTap() {
        switch state {
        case .active, .deepWorkFocus, .inMeeting:
            return  // No-op for P4 (inMeeting Calendar deep-link is P9 carry-over).
        case .away(let a):
            triggerResume(for: a)
        }
    }

    private func triggerResume(for a: YouNowAway) {
        guard shouldShowResume(a),
              let bundleID = a.lastAppBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Relative-time helper

    private func formatRelative(msAgo: Int64) -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let delta = max(0, Int((nowMs - msAgo) / 1000))
        return "\(formatDuration(TimeInterval(delta))) ago"
    }
}

// MARK: - Local helpers

extension String {
    /// Returns `nil` when empty; used to coalesce
    /// `[fields].compactMap { $0 }.joined(separator: " · ")` down to `nil`
    /// when every input was nil — so the `if let line2` branch is skipped.
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
