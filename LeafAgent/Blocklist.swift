import Foundation

/// Hardcoded Phase-1 blocklist. Editable Share Controls UI + full per-app whitelist
/// land in Phase 2 — at which point this list moves into the `share_apps` table.
///
/// Philosophy (whitepaper 03-architecture/share-controls.md): default empty whitelist,
/// but in dev mode we want to see data. Hardcoded — only Leaf itself and
/// system processes that produce no useful signals.
enum Blocklist {
    static let phase1Default: Set<String> = [
        "tech.gundem.leaf",
        "tech.gundem.leaf.agent",
        "tech.gundem.leaf.mcp",
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.dock",
        "com.apple.WindowManager"
    ]
}
