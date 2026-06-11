//
//  LaunchAgentService.swift
//  Leaf
//
//  Wrapper around SMAppService.agent(plistName:) — a user-visible toggle in
//  System Settings → Login Items → Background. The user can disable the
//  agent at any moment with a single click.
//
//  Phase 3.1 — D1 hygiene: register() filters the "already registered" SMAppServiceErrorDomain
//  so it doesn't flash a spurious red error in the Settings UI after relaunch.
//

import Foundation
import LeafCore
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class LaunchAgentService {
    /// Per-build agent label so a Debug build never clobbers the prod agent's
    /// launchd registration. Debug (bundle id contains ".debug") registers
    /// tech.gundem.leaf.debug.agent; prod registers tech.gundem.leaf.agent.
    /// The matching plist is embedded at Contents/Library/LaunchAgents/<name>.
    static var plistName: String {
        let id = Bundle.main.bundleIdentifier ?? "tech.gundem.leaf"
        return id.contains(".debug")
            ? "tech.gundem.leaf.debug.agent.plist"
            : "tech.gundem.leaf.agent.plist"
    }

    /// launchd job label in the gui domain — plist name minus extension.
    /// Used by the watchdog for `launchctl print` / `launchctl kickstart`.
    static var agentLabel: String {
        String(plistName.dropLast(".plist".count))
    }

    /// Persisted user intent: "I want background collection". Distinct from
    /// SMAppService.status — the watchdog and the launch-time auto-register
    /// act only while this is true, and never resurrect the agent after the
    /// user toggled it off. Absent key = true (pre-flag installs behaved as
    /// always-on).
    static let intentDefaultsKey = "backgroundCollectionIntent"

    var intentEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.intentDefaultsKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.intentDefaultsKey)
        }
    }

    /// SMAppService.register() re-points the BTM parent record at the bundle
    /// path of the registering copy. Registering from /tmp, a DMG or a
    /// translocated path hijacks the record away from the installed app and
    /// launchd crash-loops the agent — so auto-register is gated on this.
    var isCanonicalLocation: Bool {
        BundleLocationPolicy.isCanonical(
            bundlePath: Bundle.main.bundleURL.path,
            homePath: NSHomeDirectory())
    }

    var shouldAutoRegister: Bool {
        BundleLocationPolicy.shouldAutoRegister(
            bundleID: Bundle.main.bundleIdentifier ?? "tech.gundem.leaf",
            bundlePath: Bundle.main.bundleURL.path,
            homePath: NSHomeDirectory(),
            environment: ProcessInfo.processInfo.environment)
    }

    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastErrorMessage: String?

    private var service: SMAppService {
        SMAppService.agent(plistName: Self.plistName)
    }

    init() {
        refreshStatus()
    }

    var isEnabled: Bool { status == .enabled }

    func register() {
        intentEnabled = true
        do {
            try service.register()
            lastErrorMessage = nil
        } catch {
            // D1 (Phase 3.1) — filter "already registered" — a normal post-update
            // restoration state (LeafApp.init calls register() through an idempotent guard).
            // SMAppService returns SMAppServiceErrorDomain with message text like
            // "Service has already been registered." — a lenient filter on message text
            // vs a hardcoded error code (which varies between macOS versions).
            if isAlreadyRegisteredError(error) {
                lastErrorMessage = nil
            } else {
                lastErrorMessage = error.localizedDescription
            }
        }
        refreshStatus()
    }

    func unregister() {
        intentEnabled = false
        do {
            try service.unregister()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        refreshStatus()
    }

    func refreshStatus() {
        status = service.status
    }

    var statusDescription: String {
        switch status {
        case .enabled: "Running"
        case .notRegistered: "Not registered — toggle below to enable"
        case .notFound: "Not registered — toggle below to enable"
        case .requiresApproval: "Requires approval in System Settings"
        @unknown default: "Unknown (\(status.rawValue))"
        }
    }

    // MARK: - Private

    private func isAlreadyRegisteredError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let msg = nsError.localizedDescription.lowercased()
        return msg.contains("already") && msg.contains("registered")
    }
}

// MARK: - Test plan
//
// Manual smoke cases for Phase 3.5+ (Phase 3.4 D9 precedent):
//
// 1. Idempotent register: app relaunch with an already-registered service (LeafApp.init
//    calls register through the D1 guard) → register() filters the "already registered"
//    error → lastErrorMessage stays nil → no spurious red text in the Settings UI.
//
// 2. Real error path: e.g. a missing LaunchAgent plist → register() throws a
//    legitimate error → lastErrorMessage = localizedDescription → the user sees the
//    error in the General tab → "Last error" LabeledContent.
//
// 3. Toggle ON/OFF idempotency: user toggles ON in Settings → register() succeeds
//    → status = .enabled. Toggle OFF → unregister() → status = .notRegistered.
