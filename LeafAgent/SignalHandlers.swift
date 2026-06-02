import Foundation
import os

/// Graceful shutdown: SIGTERM/SIGINT → run shutdown closure → exit(0).
/// Keep DispatchSource refs in globals so they aren't reclaimed by ARC.
/// `nonisolated(unsafe)` — written only from `installSignalHandlers` once
/// at bootstrap, after which the sources are merely resumed inside the dispatch queue.
nonisolated(unsafe) private var sigtermSource: DispatchSourceSignal?
nonisolated(unsafe) private var sigintSource: DispatchSourceSignal?

/// Installs handlers for SIGTERM + SIGINT. The `shutdown` closure is invoked
/// serially on the main queue, inside a `Task { ... }` — i.e. it is allowed to
/// `await` on actors and DB writes. After the closure completes — `exit(0)`.
///
/// The shutdown order is set by the caller (usually maintenance → writer → exit).
func installSignalHandlers(shutdown: @Sendable @escaping () async -> Void) {
    sigtermSource = makeHandler(signal: SIGTERM, name: "SIGTERM", shutdown: shutdown)
    sigintSource = makeHandler(signal: SIGINT, name: "SIGINT", shutdown: shutdown)
}

private func makeHandler(
    signal sig: Int32,
    name: String,
    shutdown: @Sendable @escaping () async -> Void
) -> DispatchSourceSignal {
    // Disable default handler so that our DispatchSource catches the signal.
    signal(sig, SIG_IGN)

    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        agentLogger.info("Received \(name, privacy: .public) — running shutdown")
        Task {
            await shutdown()
            exit(0)
        }
    }
    source.resume()
    return source
}
