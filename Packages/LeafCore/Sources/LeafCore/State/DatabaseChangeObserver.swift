//
//  DatabaseChangeObserver.swift
//  LeafCore
//
//  Live-tabs — watches events.sqlite + its -wal sibling for cross-process
//  writes (the Agent process) and emits a debounced "database changed" signal.
//  GRDB ValueObservation can't see other processes' transactions; vnode
//  events on the WAL file can.
//
//  Lifecycle: start() on main-window appear, stop() on close — no fds, no
//  wakeups while the window is closed. If the -wal file doesn't exist yet
//  (agent never ran), a directory watcher attaches the file source once it
//  appears.
//
//  @unchecked Sendable: `sources` / `started` are confined to the private
//  serial queue — start()/stop()/reattach all hop through queue.async.
//

import Foundation
import OSLog

public final class DatabaseChangeObserver: @unchecked Sendable {

  private let databaseURL: URL
  private let debouncer: TrailingDebouncer
  private let queue = DispatchQueue(label: "tech.gundem.leaf.db-observer")
  private let logger = Logger(subsystem: "tech.gundem.leaf.core", category: "db-observer")

  private var sources: [String: DispatchSourceFileSystemObject] = [:]
  private var directorySource: DispatchSourceFileSystemObject?
  private var started = false

  public init(
    databaseURL: URL,
    debounceInterval: TimeInterval = 0.5,
    onChange: @escaping @Sendable () -> Void
  ) {
    self.databaseURL = databaseURL
    self.debouncer = TrailingDebouncer(interval: debounceInterval, action: onChange)
  }

  public func start() {
    queue.async { [self] in
      guard !started else { return }
      started = true
      attachAll()
    }
  }

  public func stop() {
    queue.async { [self] in
      guard started else { return }
      started = false
      sources.values.forEach { $0.cancel() }
      sources = [:]
      directorySource?.cancel()
      directorySource = nil
      debouncer.cancel()
    }
  }

  // MARK: - Queue-confined

  /// (Re)attach file sources for whichever of {db, db-wal} exist; watch the
  /// parent directory while the -wal is missing so we attach on its birth.
  /// Idempotent per path — existing sources are kept.
  private func attachAll() {
    guard started else { return }
    let paths = [databaseURL.path, databaseURL.path + "-wal"]
    for path in paths where sources[path] == nil {
      if let src = makeFileSource(path: path) {
        sources[path] = src
        src.activate()
      }
    }
    let walMissing = sources[databaseURL.path + "-wal"] == nil
    if walMissing, directorySource == nil {
      directorySource = makeDirectorySource()
      directorySource?.activate()
    } else if !walMissing, let dir = directorySource {
      dir.cancel()
      directorySource = nil
    }
  }

  private func makeFileSource(path: String) -> DispatchSourceFileSystemObject? {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
      // Degrade to today's on-appear behavior; log so a real fd-limit /
      // permissions fault is diagnosable.
      logger.warning("db-observer attach failed: \(path, privacy: .public) errno=\(errno)")
      return nil
    }
    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .delete, .rename],
      queue: queue
    )
    // [weak self] + dict lookup instead of capturing `src` strongly in its own
    // handler (source→handler→source cycle would persist until cancel()).
    src.setEventHandler { [weak self] in
      // Dict lookup doubles as the liveness gate — a stale handler invocation
      // surviving a stop()→start() generation can at worst read the NEW
      // source's pending data, causing one spurious debounce signal (benign).
      guard let self, let current = self.sources[path] else { return }
      let event = current.data
      self.debouncer.signal()
      // Backup&Reset / recovery flows replace the files — drop the stale fd
      // and re-attach to whatever lives at the path now.
      if event.contains(.delete) || event.contains(.rename) {
        current.cancel()
        self.sources[path] = nil
        self.attachAll()
      }
    }
    src.setCancelHandler { close(fd) }
    return src
  }

  private func makeDirectorySource() -> DispatchSourceFileSystemObject? {
    let dirPath = databaseURL.deletingLastPathComponent().path
    let fd = open(dirPath, O_EVTONLY)
    guard fd >= 0 else {
      logger.warning("db-observer dir attach failed: \(dirPath, privacy: .public) errno=\(errno)")
      return nil
    }
    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: .write, queue: queue
    )
    src.setEventHandler { [weak self] in
      guard let self else { return }
      // A file appeared/changed in the dir — if it's our -wal being born,
      // attachAll() picks it up and fires the first signal for its content.
      self.attachAll()
      if self.sources[self.databaseURL.path + "-wal"] != nil {
        self.debouncer.signal()
      }
    }
    src.setCancelHandler { close(fd) }
    return src
  }
}
