import Foundation
import os

/// Graceful shutdown: SIGTERM/SIGINT → run shutdown closure → exit(0).
/// Держим DispatchSource refs в глобалах чтобы не уехали в ARC.
/// `nonisolated(unsafe)` — write только из `installSignalHandlers` один раз
/// при bootstrap, после чего сорсы только resume'ятся внутри dispatch queue.
nonisolated(unsafe) private var sigtermSource: DispatchSourceSignal?
nonisolated(unsafe) private var sigintSource: DispatchSourceSignal?

/// Устанавливает handler'ы на SIGTERM + SIGINT. `shutdown` closure вызывается
/// сериализованно на main queue, внутри `Task { ... }` — т.е. имеет право
/// `await` на actor'ах и БД-writes. После завершения closure — `exit(0)`.
///
/// Порядок shutdown задаёт caller (обычно maintenance → writer → exit).
func installSignalHandlers(shutdown: @Sendable @escaping () async -> Void) {
    sigtermSource = makeHandler(signal: SIGTERM, name: "SIGTERM", shutdown: shutdown)
    sigintSource = makeHandler(signal: SIGINT, name: "SIGINT", shutdown: shutdown)
}

private func makeHandler(
    signal sig: Int32,
    name: String,
    shutdown: @Sendable @escaping () async -> Void
) -> DispatchSourceSignal {
    // Disable default handler так чтобы наш DispatchSource поймал сигнал.
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
