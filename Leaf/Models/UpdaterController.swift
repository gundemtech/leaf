//
//  UpdaterController.swift
//  Leaf
//
//  Phase 3.1 — Sparkle integration. Thin wrapper over SPUStandardUpdaterController.
//
//  D14 (Phase 3.1, deviation from master plan A2 D2/D8): no SPUUpdaterDelegate
//  choreography in 3.1. Sparkle's `willInstallUpdateOnQuit` only fires for the
//  silent-install-on-quit path (auto-download enabled). We have `SUEnableAutomaticChecks
//  =NO` (D10) until Phase 3.5 — this hook won't fire. The manual "Install Update" path
//  uses internal hooks without a public API.
//
//  Without the choreography flow on a manual update:
//    1. Sparkle replaces bundle + relaunches Leaf.app
//    2. New LeafApp.init → SMAppService.register (D1 guard) → launchd updates
//       registration → SIGTERM old agent process at old binary path
//    3. Old agent SignalHandlers fire (Agent.swift:131) → maintenance.stop +
//       fsEvents.stop + claudeCode.stop + writer.flush + writer.stop → exit
//    4. New agent starts at new binary path → acquires SQLCipher writer lock
//       after release by the old agent (busy_timeout from Phase 1.1; tuned value in moat)
//
//  Multi-process SQLCipher + existing SignalHandlers handle WAL gracefully.
//  Choreography would only compress timing step 2-3 (~few seconds), it does not prevent
//  data loss. If the Phase 3.5 first-release smoke catches a recovery issue — we'll add
//  an NSApplicationWillTerminateNotification observer + sync unregister + applicationShouldTerminate
//  reply pattern. Reserved for post-0.2.0 when SUEnableAutomaticChecks=YES.
//

import Foundation
import Sparkle

@MainActor
@Observable
final class UpdaterController {
    /// Sparkle controller. @ObservationIgnored — Sparkle manages its own state.
    @ObservationIgnored
    private let controller: SPUStandardUpdaterController

    init() {
        // Phase 3.5 (alpha.4) fix — `startingUpdater: false` + deferred explicit start.
        // With `startingUpdater: true` Sparkle tries to start the updater inline in App.init,
        // but the main runloop isn't active yet (NSApplicationMain spinup happens after
        // App.init returns) → start silently no-ops, checkForUpdates fails with
        // "updater hasn't been started yet" in the log and no UI dialog appears.
        // DispatchQueue.main.async defers start to the first runloop tick — runs
        // after App.init returns when NSApplication is already activated.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let controller = self.controller
        DispatchQueue.main.async {
            controller.startUpdater()
        }
    }

    /// Manual "Check for Updates…" — wired into SettingsView (Phase 3.1c).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

// MARK: - Test plan
//
// Manual smoke cases for Phase 3.5+ (Phase 3.4 D9 precedent):
//
// 1. Init smoke: UpdaterController() doesn't crash. Sparkle scheduled checks
//    are disabled (SUEnableAutomaticChecks=NO in Info.plist).
//
// 2. Manual check pre-R2: checkForUpdates() → HTTPS request to SUFeedURL
//    (updates.gundem.tech/appcast.xml) → 404 → Sparkle alert "Error checking
//    for updates" (or "Update Error"). Acceptable until Phase 3.5 R2 unblock.
//
// 3. Manual check post-R2 (no new version): checkForUpdates() → appcast.xml
//    parsed → "You're up-to-date" alert.
//
// 4. Manual check post-R2 (update available): checkForUpdates() → Sparkle
//    install dialog → user clicks "Install Update" → Sparkle terminates Leaf →
//    replace bundle → relaunch → new LeafApp.init → idempotent register
//    re-establishes Agent registration → launchd SIGTERM old agent → SignalHandlers
//    flush WAL → old agent exits → new agent starts at new binary path.
//
// 5. Quit-during-dialog: user clicks Quit between "Install Update" and the Sparkle
//    terminate sequence → Sparkle persists pending update → install on next launch.
