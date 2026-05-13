import Foundation
import CoreServices
import AppKit
import os
import LeafCore

/// Phase Track-4 S3 — single FSEventStream поверх 3 path watcher'ов
/// (screenshot dir / ~/Downloads / ~/.Trash). Routes batch events по
/// path-prefix к ScreenshotMatcher / DownloadsMatcher / TrashMatcher.
///
/// **Filename only** — никогда не читает file contents. `Data(contentsOf:)`,
/// `String(contentsOf:)`, `FileHandle(forReadingAt:)`, `FileManager.contents(atPath:)`
/// — все запрещены (ADR-010 Won't-list, walkback в T12).
@MainActor
final class LocalFilesWatcher {
    private let writer: EventWriter
    private let observersStore: SystemObserversStore
    private let coalesceWindowSec: TimeInterval
    private let screenshotDirectoryOverride: String

    private let screenshotMatcher: ScreenshotMatcher
    private let downloadsMatcher = DownloadsMatcher()
    private var trashMatcher: TrashMatcher

    // Canonicalized paths (resolved symlinks). FSEvents callback delivers
    // canonical paths via `kFSEventStreamCreateFlagUseCFTypes`, so prefix
    // dispatch needs the same canonical form to match correctly when the
    // user's screenshot directory is itself a symlink (I1 review fix).
    private var screenshotDir: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop").resolvingSymlinksInPath()
    private let downloadsDir = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads").resolvingSymlinksInPath()
    private let trashDir = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash").resolvingSymlinksInPath()

    private var streamWrapper: AgentFSEventStream?

    init(
        writer: EventWriter,
        observersStore: SystemObserversStore,
        coalesceWindowSec: TimeInterval = 2.0,
        screenshotDirectoryOverride: String = "",
        additionalScreenshotPrefixes: [String] = []
    ) {
        self.writer = writer
        self.observersStore = observersStore
        self.coalesceWindowSec = coalesceWindowSec
        self.screenshotDirectoryOverride = screenshotDirectoryOverride
        self.screenshotMatcher = ScreenshotMatcher(additionalPrefixes: additionalScreenshotPrefixes)
        self.trashMatcher = TrashMatcher(coalesceWindowMs: Int64(coalesceWindowSec * 1000))
    }

    func start() {
        screenshotDir = resolveScreenshotDir()

        var paths: [String] = []
        if observersStore.isEnabled("screenshot_watcher") { paths.append(screenshotDir.path) }
        if observersStore.isEnabled("downloads_watcher") { paths.append(downloadsDir.path) }
        if observersStore.isEnabled("trash_watcher") { paths.append(trashDir.path) }
        guard !paths.isEmpty else {
            collectorLogger.info("LocalFilesWatcher — all watch toggles disabled, skipping")
            return
        }
        do {
            streamWrapper = try AgentFSEventStream(paths: paths, latency: 0.5) { [weak self] paths, flags in
                Task { @MainActor in
                    self?.handleBatch(paths: paths, flags: flags)
                }
            }
            streamWrapper?.start()
            collectorLogger.info("LocalFilesWatcher started paths=\(paths.count, privacy: .public)")
        } catch {
            collectorLogger.error("LocalFilesWatcher init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        streamWrapper?.stop()
        streamWrapper = nil
        collectorLogger.info("LocalFilesWatcher stopped")
    }

    private func handleBatch(paths: [String], flags: [UInt32]) {
        var trashAdded = 0
        var trashRemoved = 0
        for (idx, path) in paths.enumerated() {
            let flag = idx < flags.count ? flags[idx] : 0
            let filename = (path as NSString).lastPathComponent
            let isDir = (flag & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0
            let isFile = (flag & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0

            if path.hasPrefix(screenshotDir.path) {
                handleScreenshot(flag: flag, filename: filename)
            } else if path.hasPrefix(downloadsDir.path) {
                handleDownload(flag: flag, filename: filename, isDirectory: isDir)
            } else if path.hasPrefix(trashDir.path) && isFile {
                if (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0 { trashAdded += 1 }
                if (flag & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0 { trashRemoved += 1 }
            }
        }
        if trashAdded > 0 || trashRemoved > 0 {
            handleTrashBatch(addedCount: trashAdded, removedCount: trashRemoved)
        }
    }

    private func handleScreenshot(flag: UInt32, filename: String) {
        guard observersStore.isEnabled("screenshot_watcher") else { return }
        guard (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0 else { return }
        guard screenshotMatcher.matches(filename: filename) else { return }
        let writer = self.writer
        Task {
            await writer.enqueue(RawEvent(
                signalType: .content,
                bundleID: nil,
                payload: [
                    "event_kind": "screenshot_taken",
                    "filename": filename
                ]
            ))
        }
        collectorLogger.info("Screenshot taken: \(filename, privacy: .public)")
    }

    private func handleDownload(flag: UInt32, filename: String, isDirectory: Bool) {
        guard observersStore.isEnabled("downloads_watcher") else { return }
        guard downloadsMatcher.shouldEmit(eventFlags: flag, isDirectory: isDirectory, filename: filename) else { return }
        let writer = self.writer
        Task {
            await writer.enqueue(RawEvent(
                signalType: .content,
                bundleID: nil,
                payload: [
                    "event_kind": "download_added",
                    "filename": filename
                ]
            ))
        }
        collectorLogger.info("Download added: \(filename, privacy: .public)")
    }

    private func handleTrashBatch(addedCount: Int, removedCount: Int) {
        guard observersStore.isEnabled("trash_watcher") else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard let emission = trashMatcher.observe(
            addedCount: addedCount,
            removedCount: removedCount,
            nowMs: nowMs
        ) else { return }
        let action: String
        switch emission {
        case .added:   action = "added"
        case .emptied: action = "emptied"
        }
        let writer = self.writer
        Task {
            await writer.enqueue(RawEvent(
                signalType: .context,
                bundleID: nil,
                payload: [
                    "event_kind": "trash_changed",
                    "action": action
                ]
            ))
        }
        collectorLogger.info("Trash changed: \(action, privacy: .public)")
    }

    private func resolveScreenshotDir() -> URL {
        if !screenshotDirectoryOverride.isEmpty {
            return URL(fileURLWithPath: screenshotDirectoryOverride).resolvingSymlinksInPath()
        }
        // Read from com.apple.screencapture defaults (CFPreferences).
        if let raw = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String, !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Desktop").resolvingSymlinksInPath()
    }
}

// MARK: - Private FSEventStream wrapper

/// Phase Track-4 S3 — agent-target-local FSEventStream wrapper. Mirror
/// shape `LeafCore/Internal/FSEventStream.swift` (которое internal scope).
/// Не reuse'им через public re-export, потому что LocalFilesWatcher живёт
/// в LeafAgent target — отдельный wrapper держит OS bridge на target boundary.
private final nonisolated class AgentFSEventStream: @unchecked Sendable {
    typealias EventsHandler = @Sendable (_ paths: [String], _ flags: [UInt32]) -> Void

    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let onEvents: EventsHandler

    init(
        paths: [String],
        latency: TimeInterval,
        onEvents: @escaping EventsHandler
    ) throws {
        self.queue = DispatchQueue(label: "tech.gundem.leaf.agent.localfiles", qos: .utility)
        self.onEvents = onEvents
        guard !paths.isEmpty else { throw AgentFSEventStreamError.noPaths }
        let canonicalPaths = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let cfPaths = canonicalPaths as CFArray
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
            AgentFSEventStream.callback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            throw AgentFSEventStreamError.createFailed
        }
        self.stream = ref
    }

    deinit { teardown() }

    func start() {
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() { teardown() }

    private func teardown() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info else { return }
        let owner = Unmanaged<AgentFSEventStream>.fromOpaque(info).takeUnretainedValue()
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        guard let pathsArray = cfArray as? [String] else { return }
        let flagsBuffer = UnsafeBufferPointer(start: eventFlags, count: numEvents)
        let flags: [UInt32] = flagsBuffer.map { UInt32($0) }
        owner.onEvents(pathsArray, flags)
    }
}

private enum AgentFSEventStreamError: Error, Sendable {
    case noPaths
    case createFailed
}
