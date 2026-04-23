import Foundation

/// Hardcoded Phase-1 blocklist. Editable Share Controls UI + full per-app whitelist
/// прилетают в Phase 2 — тогда этот список переезжает в `share_apps` table.
///
/// Философия (whitepaper 03-architecture/share-controls.md): default empty whitelist,
/// но в dev-режиме мы хотим видеть данные. Hardcoded — только сам LeafControl и
/// system-процессы которые полезных сигналов не дают.
enum Blocklist {
    static let phase1Default: Set<String> = [
        "tech.gundem.leafcontrol",
        "tech.gundem.leafcontrol.agent",
        "tech.gundem.leafcontrol.mcp",
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.dock",
        "com.apple.WindowManager"
    ]
}
