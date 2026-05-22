//
//  YouNowStateBadge.swift
//  Track-10 / T3 — compact YOU·NOW state badge. Inline pill living at the
//  foot of the TODAY metrics row. Replaces the full YouNowBlock card.
//
//  Structural reference: LeafStatusPill (HStack + Capsule + a11y combine).
//  Read-only; Resume CTA lives in the RESUME hero (Track-10 T2).
//

import LeafCore
import SwiftUI

struct YouNowStateBadge: View {
    let state: YouNowState

    var body: some View {
        HStack(spacing: LeafSpace.xs) {
            Image(systemName: iconName)
                .font(LeafType.body.small)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(label)
                .font(LeafType.body.small)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, LeafSpace.sm)
        .padding(.vertical, LeafSpace.xs)
        .background(Capsule().fill(tint.opacity(0.15)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    // MARK: - State → visual mapping

    private var iconName: String {
        switch state {
        case .active: return "play.fill"
        case .inMeeting: return "video.fill"
        case .deepWorkFocus: return "moon.fill"
        case .away(let a):
            switch a.reason {
            case .screenLocked: return "lock.fill"
            case .idle: return "moon.zzz.fill"
            case .sleep: return "powersleep"
            }
        }
    }

    private var tint: Color {
        switch state {
        case .active: return LeafColor.accent.primary
        case .inMeeting: return LeafColor.status.info
        case .deepWorkFocus: return LeafColor.status.warning
        case .away: return LeafColor.text.tertiary
        }
    }

    private var label: String {
        switch state {
        case .active(let s):
            return "Active · \(formatDuration(TimeInterval(s.durationSec)))"
        case .inMeeting(let m):
            if let endsAtMs = m.endsAtMsIfAvailable {
                return "In meeting · ends \(Self.hourMinuteString(endsAtMs))"
            }
            return "In meeting"
        case .deepWorkFocus(let f):
            return "Focused · \(formatDuration(TimeInterval(f.durationSec)))"
        case .away(let a):
            let dur = formatDuration(TimeInterval(a.idleSec))
            switch a.reason {
            case .screenLocked: return "Locked · \(dur)"
            case .idle: return "Idle · \(dur)"
            case .sleep: return "Asleep · \(dur)"
            }
        }
    }

    // MARK: - a11y

    private var a11yLabel: String {
        switch state {
        case .active(let s):
            return "State: Active, \(accessibilityDurationPhrase(s.durationSec))"
        case .inMeeting(let m):
            if let endsAtMs = m.endsAtMsIfAvailable {
                return "State: In meeting, ends \(Self.hourMinuteString(endsAtMs))"
            }
            return "State: In meeting"
        case .deepWorkFocus(let f):
            return "State: Focused, \(accessibilityDurationPhrase(f.durationSec))"
        case .away(let a):
            let phrase = accessibilityDurationPhrase(a.idleSec)
            switch a.reason {
            case .screenLocked: return "State: Locked, \(phrase)"
            case .idle: return "State: Idle, \(phrase)"
            case .sleep: return "State: Asleep, \(phrase)"
            }
        }
    }

    /// VoiceOver-friendly verbalisation of a duration. Compact `formatDuration`
    /// ("1h 32m", "12m", "30s") is hard to read aloud — expand to natural English
    /// units. Stays private until T6 actually reuses (YAGNI).
    private func accessibilityDurationPhrase(_ sec: Int) -> String {
        let total = max(0, sec)
        if total >= 3600 {
            let h = total / 3600
            let m = (total % 3600) / 60
            let hPart = "\(h) hour\(h == 1 ? "" : "s")"
            if m == 0 { return hPart }
            return "\(hPart) \(m) minute\(m == 1 ? "" : "s")"
        }
        if total >= 60 {
            let m = total / 60
            return "\(m) minute\(m == 1 ? "" : "s")"
        }
        return "\(total) second\(total == 1 ? "" : "s")"
    }

    // MARK: - Cached HH:mm formatter

    /// `HH:mm` rendering for `inMeeting` meeting end-time. Locale-aware
    /// (`Hm` template — 24h/12h per system locale) and cached as a static
    /// so we don't allocate a `DateFormatter` per body re-eval (same micro-perf
    /// reasoning as the YouNowBlock `startTimeFormatter` it replaces).
    private static let hourMinuteFormatter: DateFormatter = {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("Hm")
        return df
    }()

    private static func hourMinuteString(_ msSinceEpoch: Int64) -> String {
        hourMinuteFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(msSinceEpoch) / 1000))
    }
}

// MARK: - Preview catalog

#Preview("YouNowStateBadge") {
    VStack(alignment: .leading, spacing: LeafSpace.md) {
        YouNowStateBadge(state: .active(
            YouNowActive(
                app: "Xcode", bundleID: "com.apple.dt.Xcode",
                contextLabel: nil, branch: nil, linearID: nil,
                durationSec: 5520, sessionStartedAtMs: nil, intensityBars: 3)))

        YouNowStateBadge(state: .inMeeting(
            YouNowMeeting(
                titleIfAvailable: nil,
                startedAtMs: Int64(Date().timeIntervalSince1970 * 1000) - 600_000,
                endsAtMsIfAvailable: Int64(Date().timeIntervalSince1970 * 1000) + 1_800_000,
                source: .eventKit)))

        YouNowStateBadge(state: .inMeeting(
            YouNowMeeting(
                titleIfAvailable: nil,
                startedAtMs: Int64(Date().timeIntervalSince1970 * 1000) - 600_000,
                endsAtMsIfAvailable: nil,
                source: .zoom)))

        YouNowStateBadge(state: .deepWorkFocus(
            YouNowFocus(
                modeName: "Work", app: "Xcode", contextLabel: nil, durationSec: 720)))

        YouNowStateBadge(state: .away(
            YouNowAway(
                reason: .screenLocked, lastApp: "Xcode",
                lastAppBundleID: "com.apple.dt.Xcode",
                lastContextLabel: nil, lastLinearID: nil, idleSec: 480)))

        YouNowStateBadge(state: .away(
            YouNowAway(
                reason: .idle, lastApp: nil, lastAppBundleID: nil,
                lastContextLabel: nil, lastLinearID: nil, idleSec: 480)))

        YouNowStateBadge(state: .away(
            YouNowAway(
                reason: .sleep, lastApp: nil, lastAppBundleID: nil,
                lastContextLabel: nil, lastLinearID: nil, idleSec: 28_800)))
    }
    .padding(LeafSpace.lg)
}
