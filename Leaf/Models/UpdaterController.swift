//
//  UpdaterController.swift
//  Leaf
//
//  Phase 3.1 — Sparkle integration. Thin wrapper над SPUStandardUpdaterController.
//
//  D14 (Phase 3.1, deviation от master plan A2 D2/D8): no SPUUpdaterDelegate
//  choreography в 3.1. Sparkle's `willInstallUpdateOnQuit` срабатывает только для
//  silent-install-on-quit path (auto-download enabled). У нас `SUEnableAutomaticChecks
//  =NO` (D10) до Phase 3.5 — этот hook не сработает. Manual "Install Update" path
//  использует internal hooks без публичного API.
//
//  Без choreography flow при manual update:
//    1. Sparkle replaces bundle + relaunches Leaf.app
//    2. New LeafApp.init → SMAppService.register (D1 guard) → launchd updates
//       registration → SIGTERM old agent process at old binary path
//    3. Old agent SignalHandlers fire (Agent.swift:131) → maintenance.stop +
//       fsEvents.stop + claudeCode.stop + writer.flush + writer.stop → exit
//    4. New agent starts at new binary path → acquires SQLCipher writer lock
//       после release от old agent (busy_timeout из moat-config DatabaseConfigProd)
//
//  Multi-process SQLCipher + existing SignalHandlers handle WAL gracefully.
//  Choreography compress только timing step 2-3 (~few seconds), не предотвращает
//  data loss. Если Phase 3.5 first-release smoke поймёт recovery issue — добавим
//  NSApplicationWillTerminateNotification observer + sync unregister + applicationShouldTerminate
//  reply pattern. Reserved для post-0.2.0 когда SUEnableAutomaticChecks=YES.
//

import Foundation
import Sparkle

@MainActor
@Observable
final class UpdaterController {
    /// Sparkle controller. @ObservationIgnored — Sparkle сам управляет своим state.
    @ObservationIgnored
    private let controller: SPUStandardUpdaterController

    init() {
        // Phase 3.5 (alpha.4) fix — `startingUpdater: false` + deferred explicit start.
        // При `startingUpdater: true` Sparkle пытается start updater inline в App.init,
        // но main runloop ещё не активен (NSApplicationMain spinup happens после
        // App.init возврата) → start silently no-op, checkForUpdates падает с
        // "updater hasn't been started yet" в логе и UI dialog не появляется.
        // DispatchQueue.main.async откладывает start до первого runloop tick — runs
        // после возврата из App.init когда NSApplication уже activated.
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

    /// Manual "Check for Updates…" — wired в SettingsView (Phase 3.1c).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

// MARK: - Test plan
//
// Manual smoke кейсы для Phase 3.5+ (Phase 3.4 D9 precedent):
//
// 1. Init smoke: UpdaterController() не crashes. Sparkle scheduled checks
//    отключены (SUEnableAutomaticChecks=NO в Info.plist).
//
// 2. Manual check pre-R2: checkForUpdates() → HTTPS request на SUFeedURL
//    (updates.gundem.tech/appcast.xml) → 404 → Sparkle alert "Error checking
//    for updates" (или "Update Error"). Acceptable до Phase 3.5 R2 unblock.
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
// 5. Quit-during-dialog: user clicks Quit между "Install Update" и Sparkle
//    terminate sequence → Sparkle persists pending update → install on next launch.
