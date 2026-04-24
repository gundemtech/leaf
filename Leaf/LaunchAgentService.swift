//
//  LaunchAgentService.swift
//  Leaf
//
//  Обёртка над SMAppService.agent(plistName:) — user-visible toggle в
//  System Settings → Login Items → Background. Пользователь может отключить
//  agent в любой момент одним кликом.
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
            lastErrorMessage = error.localizedDescription
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
}
