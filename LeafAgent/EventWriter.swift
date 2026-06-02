import Foundation
import os
import LeafCore

/// Actor batcher: a collector calls `enqueue(_:)` without blocking; the writer,
/// every N seconds or once the batch fills up, flushes everything to the DB in a single write.
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

    /// Forced flush (for graceful shutdown).
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
            // For Phase 1 — log and drop. In Phase 2+ we can re-enqueue with a retry limit.
            writerLogger.error("Failed to write batch of \(batch.count): \(error.localizedDescription, privacy: .public)")
        }
    }
}
