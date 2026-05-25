import Foundation

public enum IDEFamily: String, Sendable, Equatable {
    case vscodeFamily
    case jetbrains
    case fallback
}

public enum IDEFamilyClassifier {
    /// 13 standard publicly-documented JetBrains macOS bundle IDs
    /// (architecture.md "JetBrains bundle list 13 (−AppCode,
    /// +DataGrip/RustRover/DataSpell)"). Exposed for re-use by future
    /// filters / detail-screen rollups.
    public static let jetbrainsBundleIDs: Set<String> = [
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.goland",
        "com.jetbrains.CLion",
        "com.jetbrains.rubymine",
        "com.google.android.studio",
        "com.jetbrains.datagrip",
        "com.jetbrains.rustrover",
        "com.jetbrains.dataspell",
    ]

    /// Terminal-family macOS bundle IDs. Used as the focused-min dwell
    /// attribution source when the user's primary task workspace is
    /// resolved via Claude Code Terminal-only workflow (aiCollaboration
    /// cwd match) rather than IDE foreground attention. Hoisted from
    /// moat-private constant per Track-10 Phase B (GUN-B 2026-05-23 —
    /// C-T10-EMIT-T7H3 carry close-out) for cross-extension reuse.
    public static let terminalFamilyBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.warp.Warp",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyperterm",
    ]

    public static func family(forBundleID id: String) -> IDEFamily {
        if VSCodeFamilyDispatcher.isVSCodeFamily(bundleID: id) {
            return .vscodeFamily
        }
        if jetbrainsBundleIDs.contains(id) {
            return .jetbrains
        }
        return .fallback
    }
}
