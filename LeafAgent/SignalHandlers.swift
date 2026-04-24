import Foundation
import os

/// Graceful shutdown: SIGTERM/SIGINT → flush EventWriter → exit(0).
/// Держим DispatchSource refs в глобалах чтобы не уехали в ARC.
private var sigtermSource: DispatchSourceSignal?
private var sigintSource: DispatchSourceSignal?

func installSignalHandlers(writer: EventWriter) {
    sigtermSource = makeHandler(signal: SIGTERM, name: "SIGTERM", writer: writer)
    sigintSource = makeHandler(signal: SIGINT, name: "SIGINT", writer: writer)
}

private func makeHandler(signal sig: Int32, name: String, writer: EventWriter) -> DispatchSourceSignal {
    // Disable default handler так чтобы наш DispatchSource поймал сигнал.
    signal(sig, SIG_IGN)

    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        agentLogger.info("Received \(name, privacy: .public) — flushing and exiting")
        Task {
            await writer.flush()
            await writer.stop()
            exit(0)
        }
    }
    source.resume()
    return source
}
