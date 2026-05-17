import CoreServices
import Foundation

/// Phase 2.4 — internal Swift wrapper над `FSEventStreamCreate` C API.
/// Не public — moat-релевантного здесь нет, но интерфейс specific к
/// реализации FSEventsCollector. Owned by collector, retained как stored property.
///
/// Concurrency:
///   - `@unchecked Sendable` — `FSEventStreamRef` thread-safe после `Schedule`
///     (документировано Apple).
///   - C callback (`@convention(c)`) без captures — self передаётся через
///     `FSEventStreamContext.info` как opaque pointer.
///   - `onEvents` callback вызывается на dispatch queue (utility QoS) — caller
///     внутри hop'ает в actor через `Task { await ... }`.
final class FSEventStream: @unchecked Sendable {
    /// Sync callback — paths + raw flags. Caller сам решает как hop'нуть в actor.
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

        // Path canonicalization — symlinks → realpath, чтобы callback paths
        // были консистентны со stored values. Делается caller'ом тоже, но
        // защищаемся defensively.
        let canonicalPaths = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let cfPaths = canonicalPaths as CFArray

        // FSEventStreamContext — info указатель на self (passUnretained ok т.к.
        // collector retains FSEventStream через stored property).
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        )

        guard
            let ref = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.callback,
                &context,
                cfPaths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            )
        else {
            throw FSEventStreamError.createFailed
        }
        self.stream = ref
    }

    deinit {
        // Defensive cleanup — collector обычно вызывает stop() явно.
        teardown()
    }

    // MARK: - Lifecycle

    /// Schedule + Start. После start callback'и идут пока не вызван stop.
    func start() {
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stop + Invalidate + Release. Идемпотентен (повторные вызовы — no-op).
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

    /// `@convention(c)` — нельзя captures. Self извлекается из `info`,
    /// preformatted CFArray<CFString> кастится в `[String]`.
    private static let callback: FSEventStreamCallback = {
        (
            _ streamRef: ConstFSEventStreamRef,
            _ clientCallBackInfo: UnsafeMutableRawPointer?,
            _ numEvents: Int,
            _ eventPaths: UnsafeMutableRawPointer,
            _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
            _ eventIds: UnsafePointer<FSEventStreamEventId>
        ) in

        guard let info = clientCallBackInfo else { return }
        let owner = Unmanaged<FSEventStream>.fromOpaque(info).takeUnretainedValue()

        // UseCFTypes => eventPaths указывает на CFArray<CFString>.
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        guard let pathsArray = cfArray as? [String] else { return }

        // Flags — fixed-size buffer в numEvents элементов; копируем в [UInt32]
        // т.к. caller (Task hop) может пережить callback (lifetime буфера — only
        // current callback invocation).
        let flagsBuffer = UnsafeBufferPointer(start: eventFlags, count: numEvents)
        let flags: [UInt32] = flagsBuffer.map { UInt32($0) }

        owner.onEvents(pathsArray, flags)
    }
}

enum FSEventStreamError: Error, Sendable {
    case noPaths
    case createFailed
}
