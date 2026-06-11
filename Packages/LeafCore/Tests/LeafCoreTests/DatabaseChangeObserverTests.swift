//
//  DatabaseChangeObserverTests.swift
//  LeafCoreTests
//
//  Live-tabs — file-watcher integration tests against a temp directory.
//  Real DispatchSource + real files; debounce interval shortened for speed.
//

import Foundation
import Testing
@testable import LeafCore

struct DatabaseChangeObserverTests {

  private func makeTempDB() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-dco-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = dir.appendingPathComponent("events.sqlite")
    try Data("head".utf8).write(to: db)
    return db
  }

  private func append(_ url: URL) throws {
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: Data("x".utf8))
  }

  @Test func walWriteFiresOnChange() async throws {
    let db = try makeTempDB()
    let wal = URL(fileURLWithPath: db.path + "-wal")
    try Data().write(to: wal)
    let box = FireBox()
    try await confirmation(expectedCount: 1) { fired in
      box.onFire = { fired() }
      let observer = DatabaseChangeObserver(
        databaseURL: db, debounceInterval: 0.05, onChange: { box.fire() }
      )
      observer.start()
      defer { observer.stop() }
      try? await Task.sleep(nanoseconds: 100_000_000)  // let sources attach
      try append(wal)
      try? await Task.sleep(nanoseconds: 400_000_000)
    }
  }

  @Test func walCreatedAfterStartAttachesAndFires() async throws {
    let db = try makeTempDB()  // no -wal yet
    let wal = URL(fileURLWithPath: db.path + "-wal")
    let box = FireBox()
    try await confirmation(expectedCount: 1) { fired in
      box.onFire = { fired() }
      let observer = DatabaseChangeObserver(
        databaseURL: db, debounceInterval: 0.05, onChange: { box.fire() }
      )
      observer.start()
      defer { observer.stop() }
      try? await Task.sleep(nanoseconds: 100_000_000)
      try Data("born".utf8).write(to: wal)  // dir event → attach + fire
      try? await Task.sleep(nanoseconds: 400_000_000)
    }
  }

  @Test func stopSilencesFurtherWrites() async throws {
    let db = try makeTempDB()
    let wal = URL(fileURLWithPath: db.path + "-wal")
    try Data().write(to: wal)
    let box = FireBox()
    try await confirmation(expectedCount: 0) { fired in
      box.onFire = { fired() }
      let observer = DatabaseChangeObserver(
        databaseURL: db, debounceInterval: 0.05, onChange: { box.fire() }
      )
      observer.start()
      try? await Task.sleep(nanoseconds: 100_000_000)
      observer.stop()
      try? await Task.sleep(nanoseconds: 100_000_000)
      try append(wal)
      try? await Task.sleep(nanoseconds: 300_000_000)
    }
  }

  @Test func startStopAreIdempotent() async throws {
    let db = try makeTempDB()
    let observer = DatabaseChangeObserver(
      databaseURL: db, debounceInterval: 0.05, onChange: {}
    )
    observer.start()
    observer.start()
    observer.stop()
    observer.stop()
    observer.start()
    observer.stop()
    // No crash / leak assertion — the test is "this sequence is legal".
  }
}

/// Confirmation's `fired` is not @Sendable-capturable into arbitrary queues
/// directly — route through a tiny Sendable box (same pattern as TrailingDebouncerTests).
private final class FireBox: @unchecked Sendable {
  var onFire: (@Sendable () -> Void)?
  func fire() { onFire?() }
}
