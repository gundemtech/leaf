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
    @Environment(RouteCoordinator.self) private var coordinator
    @Environment(WindowState.self) private var windowState
    @Environment(PermissionsService.self) private var permissions

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("YOU · NOW")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                cardContent
                    .animation(.easeInOut(duration: 0.25), value: state)
            }
            .overlay(
                RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous)
                    .strokeBorder(stateBorderTint, lineWidth: 1)
                    .animation(.easeInOut(duration: 0.25), value: state)
            )
            .modifier(YouNowTapModifier(state: state, handleTap: handleTap))
        }
    }

    /// Tone-tinted card border per state — matches Figma mockup §3 in
    /// master spec where the YOU·NOW card is outlined in the state colour
    /// (extra signal beyond the leading IconChip tint). `.away` reverts
    /// to LeafCard's default subtle border by rendering a clear stroke.
    private var stateBorderTint: Color {
        switch state {
        case .active: return LeafColor.accent.primary.opacity(0.4)
        case .inMeeting: return LeafColor.status.info.opacity(0.4)
        case .deepWorkFocus: return LeafColor.status.warning.opacity(0.4)
        case .away: return .clear
        }
    }

    // MARK: - State dispatch

    @ViewBuilder
    private var cardContent: some View {
        switch state {
        case .active(let s): activeContent(s)
        case .inMeeting(let m): meetingContent(m)
        case .deepWorkFocus(let f): focusContent(f)
        case .away(let a): awayContent(a)
        }
    }

    @ViewBuilder
    private func activeContent(_ s: YouNowActive) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            rowLayout(
                iconSystemName: "play.circle.fill",
                tint: LeafColor.accent.primary,
                bundleIDForIcon: s.bundleID,
                title: s.app,
                titleTint: LeafColor.accent.primary,
                line2: [s.contextLabel, s.branch, s.linearID].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                line3: activeTimeLine(s),
                trailingBars: s.intensityBars
            )
            if shouldShowIntensityHint(s) {
                intensityHintLink
            }
        }
    }

    /// Track-9 T5 D-14 — hint condition: zero intensity bars.
    ///
    /// Proxy heuristic: `intensityBars == 0` covers both "TCC not granted"
    /// (PermissionsService.inputMonitoringGranted == false) and "user toggle
    /// OFF" (SystemObserversStore.isEnabled("intensity") == false). No single
    /// `intensityAggregatorEnabled: Bool` property exists on the public API;
    /// the proxy is correct for the intended UX — show hint whenever bars are
    /// absent, regardless of the root cause. ADR-010: no key-content stored.
    private func shouldShowIntensityHint(_ s: YouNowActive) -> Bool {
        s.intensityBars == 0
    }

    private var intensityHintLink: some View {
        Button {
            coordinator.route(
                .settings(section: .systemObservers, sub: nil),
                windowState: windowState)
        } label: {
            Text("Enable intensity monitoring")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .underline()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings to enable intensity monitoring")
    }

    @ViewBuilder
    private func meetingContent(_ m: YouNowMeeting) -> some View {
        rowLayout(
            iconSystemName: "video.fill",
            tint: LeafColor.status.info,
            bundleIDForIcon: nil,
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
            iconSystemName: "moon.fill",
            tint: LeafColor.status.warning,
            bundleIDForIcon: nil,
            title: "Deep work: \(f.modeName ?? "Focus")",
            titleTint: LeafColor.status.warning,
            line2: [f.app, f.contextLabel, f.branch, f.linearID]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
            line3: formatDuration(TimeInterval(f.durationSec)),
            trailingBars: 0
        )
    }

    @ViewBuilder
    private func awayContent(_ a: YouNowAway) -> some View {
        let (icon, titleText, timeFooter) = awayPresentation(for: a)
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            rowLayout(
                iconSystemName: icon,
                tint: LeafColor.text.tertiary,
                bundleIDForIcon: a.lastAppBundleID,
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

    /// Track-9 T5 — mockup §3 wording: "42m focused" (drops "Started HH:MM ·"
    /// surface; duration alone communicates session length per spec D-13).
    private func activeTimeLine(_ s: YouNowActive) -> String {
        "\(formatDuration(TimeInterval(s.durationSec))) focused"
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
        iconSystemName: String,
        tint: Color,
        bundleIDForIcon: String?,
        title: String,
        titleTint: Color,
        line2: String?,
        line3: String?,
        trailingBars: Int
    ) -> some View {
        HStack(alignment: .top, spacing: LeafSpace.md) {
            leadingIcon(systemName: iconSystemName, tint: tint, bundleID: bundleIDForIcon)
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
            // Phase 8.9 a11y: collapse title + line2 + line3 into one
            // VoiceOver element so the YOU·NOW row reads as a single
            // sentence rather than three separate texts.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func intensityBarsView(count: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Rectangle()
                    .fill(LeafColor.accent.primary)
                    .frame(width: 3, height: 8)
                    .opacity(i < count ? 1.0 : 0.25)
            }
        }
        .accessibilityElement(children: .ignore)
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
        // Safe to force-unwrap: `shouldShowResume` already gated on both
        // `lastLinearID != nil` and `lastAppBundleID != nil`; `lastApp`
        // (display name) defaults to the bundle id when display lookup
        // misses, so we still want a final string fallback there.
        // Track-9 T5 D-6: LinearID-aware CTA label — "Resume LEAF-204" when
        // lastLinearID is known, generic "Resume" otherwise (4-gate eligibility
        // is unchanged; only the visible text adapts).
        let label = a.lastLinearID.map { "Resume \($0)" } ?? "Resume"
        let appLabel = a.lastApp ?? a.lastAppBundleID ?? "app"
        Button {
            triggerResume(for: a)
        } label: {
            Text("→ \(label) in \(appLabel)")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.accent.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) in \(appLabel)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Tap handling

    /// `.onTapGesture` is gated by `YouNowTapModifier` to `.away` only, so
    /// this method always runs in away context. `.active` / `.deepWorkFocus`
    /// are intentionally inert; `.inMeeting` `ical://` deep-link is P9.
    private func handleTap() {
        guard case .away(let a) = state else { return }
        triggerResume(for: a)
    }

    private func triggerResume(for a: YouNowAway) {
        guard shouldShowResume(a),
            let bundleID = a.lastAppBundleID,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Relative-time helper

    /// C-22 (Phase 8.9) — migrated to `HomeRelativeTimeFormatter`. Thin
    /// wrapper preserves both call sites (`meetingContent` / `awayContent`).
    /// Bucket ladder now matches WhereStoppedBlock + WithYouOnThisBlock: the
    /// formatDuration-based "X min ago" phrasing is replaced by canonical
    /// "Nm ago / Nh ago / yesterday / N days ago / MMM d".
    private func formatRelative(msAgo: Int64) -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return HomeRelativeTimeFormatter.format(deltaMs: max(0, nowMs - msAgo), nowMs: nowMs)
    }

    // MARK: - Leading icon (app icon when known, fallback to SF chip)

    /// Prefer the real macOS app icon when we have a bundle id — it's the
    /// fastest visual anchor for "what app". Falls back to the tone-tinted
    /// SF symbol chip for states without a bundle (meeting / focus
    /// without app context / cold-empty away).
    @ViewBuilder
    private func leadingIcon(systemName: String, tint: Color, bundleID: String?) -> some View {
        if let bundleID, let icon = Self.appIcon(forBundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous))
                .accessibilityHidden(true)
        } else {
            LeafIconChip(systemName: systemName, size: .md, tint: tint)
                .accessibilityHidden(true)
        }
    }

    /// Resolve the macOS app icon for a bundle id via NSWorkspace. Returns
    /// `nil` for unknown / uninstalled bundles — caller falls back to the SF
    /// chip. Cached implicitly by NSWorkspace; per-call cost is negligible
    /// at human-perceivable cadences.
    private static func appIcon(forBundleID bundleID: String) -> NSImage? {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Cached `HH:mm` formatter — locale-aware (`setLocalizedDateFormatFromTemplate`)
    /// without per-render allocation. Phase 8.4 carry-fix in the spirit of master
    /// §9.1 C-4 (TODAY DateFormatter caching) — same micro-perf reasoning.
    private static let startTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("HH:mm")
        return f
    }()

    fileprivate static func startTimeString(msSinceEpoch: Int64) -> String {
        startTimeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(msSinceEpoch) / 1000))
    }
}

// MARK: - Local helpers

extension String {
    /// Returns `nil` when empty; used to coalesce
    /// `[fields].compactMap { $0 }.joined(separator: " · ")` down to `nil`
    /// when every input was nil — so the `if let line2` branch is skipped.
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Gate the tap affordance behind `.away` only — non-away states stay
/// non-interactive per master spec §3.4 (inMeeting `ical://` deep-link is
/// Track-9 carry C-6; active / deepWorkFocus describe the user's own
/// current state and are intentionally inert).
///
/// C-7 (Phase 8.9) — outer `.away` keeps `.contentShape + .onTapGesture`
/// for the whole-card tap surface (cursor signal preserved). VoiceOver
/// discoverability comes via `.accessibilityAction(named:)` — a rotor-
/// addressable action attached to the implicit container element. This
/// avoids the nested-Button anti-pattern that would clash with the inner
/// `resumeCTA(for:)` Button (which keeps its own `.isButton` trait +
/// label and stays independently focusable per macOS HIG).
private struct YouNowTapModifier: ViewModifier {
    let state: YouNowState
    let handleTap: () -> Void

    func body(content: Content) -> some View {
        switch state {
        case .away:
            content
                .contentShape(Rectangle())
                .onTapGesture { handleTap() }
                .accessibilityAction(named: Text("Resume")) { handleTap() }
        case .active, .inMeeting, .deepWorkFocus:
            content
        }
    }
}
