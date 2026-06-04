import Foundation
import AppKit
import os
import LeafCore

/// Phase Track-4 S2 — orchestrator over per-app AppleScript adapters. Spawns
/// one polling Task per adapter and delegates each tick to the pure
/// `AppleScriptDispatchLogic` in LeafCore (where it can be SPM-tested).
///
/// On `stop()` all tasks are cancelled. Adapter state machines live inside
/// the adapter instances themselves; the collector copies a fresh adapter
/// state across ticks by holding the adapter array as `var`.
@MainActor
final class AppleScriptCollector {
    private let bridge: AppleScriptBridge
    private let permissionStore: AppleScriptPermissionStore
    private let localAppsStore: LocalAppsStore
    private var adapters: [any AppleScriptAdapter]
    private let writer: EventWriter
    private let logger = Logger(subsystem: "tech.gundem.leaf.agent", category: "AppleScriptCollector")
    private var tasks: [Task<Void, Never>] = []

    init(
        bridge: AppleScriptBridge,
        permissionStore: AppleScriptPermissionStore,
        localAppsStore: LocalAppsStore,
        registry: any AppleScriptAdapterRegistry,
        writer: EventWriter
    ) {
        self.bridge = bridge
        self.permissionStore = permissionStore
        self.localAppsStore = localAppsStore
        self.adapters = registry.adapters
        self.writer = writer
    }

    func start() async {
        guard !adapters.isEmpty else {
            logger.info("AppleScriptCollector skipped — empty adapter registry")
            return
        }
        // We dispatch ticks sequentially over adapter indices so each adapter's
        // mutating state machine stays consistent. One polling Task per adapter.
        for index in adapters.indices {
            let interval = adapters[index].pollIntervalSec
            let task = Task<Void, Never> { [weak self] in
                while !Task.isCancelled {
                    await self?.tickAdapter(at: index)
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }
            tasks.append(task)
        }
        logger.info("AppleScriptCollector started \(self.adapters.count, privacy: .public) adapters")
    }

    func stop() async {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        logger.info("AppleScriptCollector stopped")
    }

    private func tickAdapter(at index: Int) async {
        guard index < adapters.count else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Extract → mutate → write back. Swift 6 forbids passing actor-isolated
        // subscript inout across an async boundary; we serialize the mutation
        // through a local copy.
        //
        // Prod adapters currently keep per-tick state inside a class-backed
        // `StateMachineBox`, so the value-copy is effectively a no-op for them
        // (the reference makes mutations visible across copies). We still
        // write back for correctness — a future struct-state adapter (no box)
        // would rely on this to retain its state machine progress.
        var adapter = adapters[index]
        let outcome = await AppleScriptDispatchLogic.tickAdapter(
            &adapter,
            bridge: bridge,
            permissionStore: permissionStore,
            localAppsStore: localAppsStore,
            isInstalled: { bundleID in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            },
            isRunning: { bundleID in
                NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
            },
            nowMs: nowMs
        )
        adapters[index] = adapter
        for ev in outcome.events {
            await writer.enqueue(ev)
        }
        for diag in outcome.diagnostics {
            switch diag {
            case .timeout(let bid):
                logger.warning("AS timeout for \(bid, privacy: .public)")
            case .scriptError(let bid, let code, _):
                logger.warning("AS script error \(code, privacy: .public) for \(bid, privacy: .public)")
            }
        }
    }
}
