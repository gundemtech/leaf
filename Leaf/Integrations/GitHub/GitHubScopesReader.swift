//
//  GitHubScopesReader.swift
//  Leaf
//
//  Phase Track-3 D2 — Task 16. @Observable wrapper around GitHubScopesService
//  exposing a synchronous `state: ShipState` property SwiftUI views can bind
//  to. Polls `service.missing()` on `refresh()` and on the
//  `tech.gundem.leaf.github-integration-changed` DistributedNotification (fired
//  by GitHubOAuthService after Device Flow completion / token refresh).
//
//  Why a separate reader (not direct service use): the actor's async-await
//  surface doesn't compose cleanly with SwiftUI; the reader owns the
//  `unknown` initial state UI treats as non-actionable until the first
//  refresh lands.
//
//  Mirror MemberRemovalReader / PendingInvitesReader: @MainActor @Observable
//  with `Observation` import + DistributedNotificationCenter observer + deinit
//  cleanup. Service is injected (not lazy-init Database) — composition root
//  builds GitHubScopesService once and hands it here.
//

import Foundation
import Observation
import LeafCore

@MainActor
@Observable
final class GitHubScopesReader {
    enum ShipState: Sendable, Equatable {
        case unknown
        case connected
        case connectedScopeOutdated(missing: Set<String>)
        case notConfigured
    }

    private(set) var state: ShipState = .unknown

    private let service: GitHubScopesService?
    /// `nonisolated(unsafe)` because `deinit` is non-isolated in Swift 6, and
    /// `DistributedNotificationCenter.removeObserver` is thread-safe. Written
    /// once in `subscribeIntegrationChanged()` (MainActor) at init.
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(service: GitHubScopesService?) {
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
        let name = NSNotification.Name(GitHubOAuthEndpoints.integrationChangedNotificationName)
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
