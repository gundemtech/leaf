//
//  SlackScopesReader.swift
//  Leaf
//
//  Phase Track-3 D3 — Task 11. @Observable wrapper around SlackScopesService
//  exposing a synchronous `state: ShipState` property SwiftUI views can bind
//  to. Polls `service.missing()` on `refresh()` and on the
//  `tech.gundem.leaf.slack-integration-changed` DistributedNotification (fired
//  by SlackOAuthService after PKCE flow completion / token refresh).
//
//  Why a separate reader (not direct service use): the actor's async-await
//  surface doesn't compose cleanly with SwiftUI; the reader owns the
//  `unknown` initial state UI treats as non-actionable until the first
//  refresh lands.
//
//  Mirror GitHubScopesReader (Task 16 of D2) byte-for-byte: @MainActor
//  @Observable with `Observation` import + DistributedNotificationCenter
//  observer + deinit cleanup. Service is injected (not lazy-init Database) —
//  composition root builds SlackScopesService once and hands it here.
//

import Foundation
import Observation
import LeafCore

@MainActor
@Observable
final class SlackScopesReader {
    enum ShipState: Sendable, Equatable {
        case unknown
        case connected
        case connectedScopeOutdated(missing: Set<String>)
        case notConfigured
    }

    private(set) var state: ShipState = .unknown

    private let service: SlackScopesService?
    /// `nonisolated(unsafe)` так как `deinit` non-isolated в Swift 6, а
    /// `DistributedNotificationCenter.removeObserver` thread-safe. Запись
    /// единожды в `subscribeIntegrationChanged()` (MainActor) при init.
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(service: SlackScopesService?) {
        self.service = service
        subscribeIntegrationChanged()
        Task { await refresh() }
    }

    func refresh() async {
        guard let service else {
            state = .notConfigured
            return
        }
        await service.refresh()
        let missing = await service.missing()
        state = missing.isEmpty ? .connected : .connectedScopeOutdated(missing: missing)
    }

    private func subscribeIntegrationChanged() {
        let name = NSNotification.Name(SlackOAuthEndpoints.integrationChangedNotificationName)
        observer = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
