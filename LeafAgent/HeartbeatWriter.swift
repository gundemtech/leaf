import ApplicationServices
import Foundation
import LeafCore
import os

/// Cross-process status pipe — the Agent periodically writes a heartbeat file
/// so the main app can show in Settings → Diagnostics "Agent alive, AX granted,
/// CDHash X, last heartbeat N sec ago". See `LeafCore.DebugHeartbeat`
/// for the shape + canonical path.
///
/// Does not throw: write failures are logged once and swallowed — the heartbeat
/// is optional and must not take down the Agent.
actor HeartbeatWriter {
    private let intervalSec: TimeInterval
    private var task: Task<Void, Never>?
    private var loggedWriteFailure = false
    private let logger = Logger(subsystem: "tech.gundem.leaf.agent", category: "heartbeat")

    init(intervalSec: TimeInterval = 30) {
        self.intervalSec = intervalSec
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.writeOnce()
                let ns = UInt64(await self.intervalSec * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func writeOnce() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let axTrusted = AXIsProcessTrusted()
        let cdHash = DebugDiagnostics.currentProcessCDHash()
        let bundlePath = DebugDiagnostics.currentProcessBundlePath()
        let tsMs = Int64(Date().timeIntervalSince1970 * 1000)

        let heartbeat = DebugHeartbeat(
            pid: pid,
            axTrusted: axTrusted,
            cdHash: cdHash,
            bundlePath: bundlePath,
            tsMs: tsMs
        )
        do {
            try heartbeat.write()
            // Reset "logged failure once" so that new failures get logged too.
            loggedWriteFailure = false
        } catch {
            if !loggedWriteFailure {
                logger.error(
                    "Failed to write agent-heartbeat.json: \(error.localizedDescription, privacy: .public)"
                )
                loggedWriteFailure = true
            }
        }
    }
}
