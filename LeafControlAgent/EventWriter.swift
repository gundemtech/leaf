import Foundation
import os
import LeafControlCore

/// Actor-батчер: коллектор зовёт `enqueue(_:)` не блокируя, writer раз в N секунд
/// или при достижении батча кидает всё в DB одним write.
actor EventWriter {
    private let database: Database
    private let thresholds: AgentThresholds
    private var buffer: [RawEvent] = []
    private var periodicFlush: Task<Void, Never>?

    init(database: Database, thresholds: AgentThresholds) {
        self.database = database
        self.thresholds = thresholds
    }

    func start() {
        let interval = thresholds.eventFlushIntervalSec
        periodicFlush = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.flush()
            }
        }
    }

    func stop() {
        periodicFlush?.cancel()
        periodicFlush = nil
    }

    func enqueue(_ event: RawEvent) {
        buffer.append(event)
        if buffer.count >= thresholds.eventFlushBatchSize {
            flushLocked()
        }
    }

    /// Принудительный flush (для graceful shutdown).
    func flush() {
        flushLocked()
    }

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)

        do {
            try database.write(batch)
            writerLogger.debug("Flushed \(batch.count) events")
        } catch {
            // Для Phase 1 — log and drop. В Phase 2+ можно re-enqueue с лимитом retry.
            writerLogger.error("Failed to write batch of \(batch.count): \(error.localizedDescription, privacy: .public)")
        }
    }
}
