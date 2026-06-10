//
//  TrailingDebouncerTests.swift
//  LeafCoreTests
//
//  Live-tabs — trailing-edge debounce for DatabaseChangeObserver.
//

import Foundation
import Testing
@testable import LeafCore

struct TrailingDebouncerTests {

  @Test func burstCollapsesToOneAction() async {
    await confirmation(expectedCount: 1) { fired in
      let box = FireBox(onFire: { fired() })
      let d = TrailingDebouncer(interval: 0.05) { box.fire() }
      for _ in 0..<10 { d.signal() }
      // Trailing edge: wait past the interval for the single fire.
      try? await Task.sleep(nanoseconds: 300_000_000)
    }
  }

  @Test func separatedBurstsFireSeparately() async {
    await confirmation(expectedCount: 2) { fired in
      let box = FireBox(onFire: { fired() })
      let d = TrailingDebouncer(interval: 0.05) { box.fire() }
      d.signal()
      try? await Task.sleep(nanoseconds: 200_000_000)
      d.signal()
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
  }

  @Test func cancelSuppressesPendingFire() async {
    await confirmation(expectedCount: 0) { fired in
      let box = FireBox(onFire: { fired() })
      let d = TrailingDebouncer(interval: 0.05) { box.fire() }
      d.signal()
      d.cancel()
      try? await Task.sleep(nanoseconds: 300_000_000)
    }
  }
}

/// Confirmation's `fired` is not @Sendable-capturable into the debouncer's
/// queue directly in all toolchains — route through a tiny Sendable box.
private final class FireBox: @unchecked Sendable {
  private let onFire: @Sendable () -> Void
  init(onFire: @escaping @Sendable () -> Void) { self.onFire = onFire }
  func fire() { onFire() }
}
