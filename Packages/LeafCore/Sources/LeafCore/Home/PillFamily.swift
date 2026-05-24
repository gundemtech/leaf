//
//  PillFamily.swift
//  Track-9 T6 — canonical namespace for TODAY pill families (master spec
//  scope lock #6). 13 cases: 10 capture-time families (Claude / Xcode / IDEs /
//  Browsers / Zoom / Calendar / Mail / Notes / Music / Reminders) + 3 Layer B
//  providers (Linear / GitHub / Slack). `rawValue` aligns with `HomeSurface`
//  for capture surfaces and `LayerBProvider` for Layer B.
//
//  `kind` discriminator drives `TodayBlock` pillStrip label format: capture
//  families render "X 1h 23m" (count = seconds), action-noun render "X 3"
//  (count = discrete events).
//
//  Bundle ID composition for capture families lives in LeafCorePrivate moat
//  (`ProdTodayPillFamilyMap`) per pre-push-leaf checklist.
//

import Foundation

public enum PillFamily: String, CaseIterable, Equatable, Hashable, Sendable {
    // Capture surfaces (6) — rawValues match HomeSurface
    case claudeCode
    case xcode
    case ides
    case browsers
    case zoom
    case calendar

    // Track-4 S2 capture families (4) — Apple's first-party surfaces
    case mail
    case notes
    case music
    case reminders

    // Layer B providers (3) — rawValues match LayerBProvider
    case linear
    case github
    case slack

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude"
        case .xcode: "Xcode"
        case .ides: "IDEs"
        case .browsers: "Browsers"
        case .zoom: "Zoom"
        case .calendar: "Calendar"
        case .mail: "Mail"
        case .notes: "Notes"
        case .music: "Music"
        case .reminders: "Reminders"
        case .linear: "Linear"
        case .github: "GitHub"
        case .slack: "Slack"
        }
    }

    public var kind: SurfacePillKind {
        // Explicit per-case to force compile error if a future case is added
        // without an explicit kind decision (e.g. another action-noun family).
        switch self {
        case .claudeCode, .xcode, .ides, .browsers, .zoom, .calendar,
             .mail, .notes, .music, .reminders:
            .captureTime
        case .linear, .github, .slack:
            .actionNoun
        }
    }
}
