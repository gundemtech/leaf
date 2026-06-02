import Foundation
import CoreServices

/// Phase 2.4 — internal Swift wrapper over the `FSEventStreamCreate` C API.
/// Not public — nothing moat-relevant here, but the interface is specific to
/// the FSEventsCollector implementation. Owned by the collector, retained as a stored property.
///
/// Concurrency:
///   - `@unchecked Sendable` — `FSEventStreamRef` is thread-safe after `Schedule`
///     (documented by Apple).
///   - The C callback (`@convention(c)`) has no captures — self is passed via
///     `FSEventStreamContext.info` as an opaque pointer.
///   - The `onEvents` callback is invoked on a dispatch queue (utility QoS) — the caller
///     inside hops into the actor via `Task { await ... }`.
final class FSEventStream: @unchecked Sendable {
    /// Sync callback — paths + raw flags. The caller decides how to hop into the actor.
    typealias EventsHandler = @Sendable (_ paths: [String], _ flags: [UInt32]) -> Void

    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let onEvents: EventsHandler

    init(
        paths: [String],
        latency: TimeInterval,
        queueLabel: String = "tech.gundem.leaf.fsevents",
        onEvents: @escaping EventsHandler
    ) throws {
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
        self.onEvents = onEvents

        guard !paths.isEmpty else {
            throw FSEventStreamError.noPaths
        }

        // Path canonicalization — symlinks → realpath, so callback paths
        // are consistent with stored values. Done by the caller too, but
        // we guard defensively.
        let canonicalPaths = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let cfPaths = canonicalPaths as CFArray

        // FSEventStreamContext — info points to self (passUnretained is ok since
        // the collector retains FSEventStream via a stored property).
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let ref = FSEventStreamCreate(
            kCFAllocatorDefault,
            FSEventStream.callback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            throw FSEventStreamError.createFailed
        }
        self.stream = ref
    }

    deinit {
        // Defensive cleanup — the collector usually calls stop() explicitly.
        teardown()
    }

    // MARK: - Lifecycle

    /// Schedule + Start. After start, callbacks keep coming until stop is called.
    func start() {
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stop + Invalidate + Release. Idempotent (repeated calls — no-op).
    func stop() {
        teardown()
    }

    private func teardown() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    // MARK: - C callback bridge

    /// `@convention(c)` — no captures allowed. Self is extracted from `info`,
    /// and the preformatted CFArray<CFString> is cast to `[String]`.
    private static let callback: FSEventStreamCallback = {
        (_ streamRef: ConstFSEventStreamRef,
         _ clientCallBackInfo: UnsafeMutableRawPointer?,
         _ numEvents: Int,
         _ eventPaths: UnsafeMutableRawPointer,
         _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
         _ eventIds: UnsafePointer<FSEventStreamEventId>) -> Void in

        guard let info = clientCallBackInfo else { return }
        let owner = Unmanaged<FSEventStream>.fromOpaque(info).takeUnretainedValue()

        // UseCFTypes => eventPaths points to a CFArray<CFString>.
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        guard let pathsArray = cfArray as? [String] else { return }

        // Flags — fixed-size buffer of numEvents elements; copy into [UInt32]
        // because the caller (Task hop) may outlive the callback (the buffer's
        // lifetime is only the current callback invocation).
        let flagsBuffer = UnsafeBufferPointer(start: eventFlags, count: numEvents)
        let flags: [UInt32] = flagsBuffer.map { UInt32($0) }

        owner.onEvents(pathsArray, flags)
    }
}

enum FSEventStreamError: Error, Sendable {
    case noPaths
    case createFailed
}
