//
//  LaunchAgentService.swift
//  Leaf
//
//  Обёртка над SMAppService.agent(plistName:) — user-visible toggle в
//  System Settings → Login Items → Background. Пользователь может отключить
//  agent в любой момент одним кликом.
//
//  Phase 3.1 — D1 hygiene: register() filter "already registered" SMAppServiceErrorDomain
//  чтобы не флешить spurious red error в Settings UI после relaunch.
//

import Foundation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class LaunchAgentService {
    static let plistName = "tech.gundem.leaf.agent.plist"

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
        do {
            try service.register()
            lastErrorMessage = nil
        } catch {
            // D1 (Phase 3.1) — filter "already registered" — нормальный post-update
            // restoration state (LeafApp.init вызывает register() через idempotent guard).
            // SMAppService возвращает SMAppServiceErrorDomain с message text типа
            // "Service has already been registered." — щадящий filter по message text
            // vs hardcoded error code (varies между macOS versions).
            if isAlreadyRegisteredError(error) {
                lastErrorMessage = nil
            } else {
                lastErrorMessage = error.localizedDescription
            }
        }
        refreshStatus()
    }

    func unregister() {
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
// Manual smoke кейсы для Phase 3.5+ (Phase 3.4 D9 precedent):
//
// 1. Idempotent register: app relaunch с уже-registered service (LeafApp.init
//    вызывает register через D1 guard) → register() filters "already registered"
//    error → lastErrorMessage остаётся nil → no spurious red text в Settings UI.
//
// 2. Real error путь: например, missing LaunchAgent plist → register() throws
//    legitimate error → lastErrorMessage = localizedDescription → user видит
//    error в General tab → "Last error" LabeledContent.
//
// 3. Toggle ON/OFF idempotency: user toggle ON в Settings → register() succeeds
//    → status = .enabled. Toggle OFF → unregister() → status = .notRegistered.
