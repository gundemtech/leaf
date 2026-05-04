//
//  AppCategoryClassifier.swift
//  LeafCore
//
//  Phase 4.10.B — static category classification по bundle ID. Используется
//  UI для colored category dot (Activity tab / Recent Sessions) и
//  `DefaultAttentionGranularityPolicy` для дефолтных granularity ceilings.
//
//  Hardcoded set'ы — Phase 4.10.B scope. User-customization откладывается до
//  Settings rework (см. plan "Что НЕ в 4.10.B").
//

import Foundation

public enum AppCategory: String, Sendable, Hashable, CaseIterable {
    case dev
    case browse
    case communication
    case design
    case other
}

public enum AppCategoryClassifier {
    public static let dev: Set<String> = [
        "com.apple.dt.Xcode",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.microsoft.VSCode",
        "com.visualstudio.code.oss",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
        "dev.zed.Zed",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.AppCode",
        "com.github.GitHubDesktop",
        "com.tower3.Tower3"
    ]

    public static let browse: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",       // Arc
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera"
    ]

    public static let communication: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "ru.keepcoder.Telegram",
        "com.apple.Mail",
        "com.apple.MobileSMS",
        "com.hnc.Discord",
        "com.microsoft.teams2",
        "us.zoom.xos",
        "com.apple.facetime",
        "org.whispersystems.signal-desktop",
        "com.notion.id"
    ]

    public static let design: Set<String> = [
        "com.figma.Desktop",
        "com.bohemiancoding.sketch3",
        "com.apple.Preview",
        "com.adobe.Photoshop",
        "com.adobe.illustrator",
        "com.framer.electron",
        "com.invisionapp.studio"
    ]

    public static func category(for bundleID: String) -> AppCategory {
        if dev.contains(bundleID) { return .dev }
        if browse.contains(bundleID) { return .browse }
        if communication.contains(bundleID) { return .communication }
        if design.contains(bundleID) { return .design }
        return .other
    }
}
