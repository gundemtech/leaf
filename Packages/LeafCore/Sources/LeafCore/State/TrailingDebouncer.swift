//
//  TrailingDebouncer.swift
//  LeafCore
//
//  Live-tabs — trailing-edge debounce. A burst of signal() calls produces one
//  action() after `interval` of quiet. Used by DatabaseChangeObserver to absorb
//  SQLite write bursts (one transaction = many vnode events).
//
//  @unchecked Sendable: `pending` is confined to the private serial queue —
//  every read/write happens via queue.async.
//

import Foundation

public final class TrailingDebouncer: @unchecked Sendable {

  private let interval: TimeInterval
  private let action: @Sendable () -> Void
  private let queue: DispatchQueue
  private var pending: DispatchWorkItem?

  public init(
    interval: TimeInterval,
    /// Must be a SERIAL queue — confinement (and `@unchecked Sendable`) is unsound on a concurrent queue.
    queue: DispatchQueue = DispatchQueue(label: "tech.gundem.leaf.debounce"),
    action: @escaping @Sendable () -> Void
  ) {
    self.interval = interval
    self.queue = queue
    self.action = action
  }

  /// Schedule (or re-schedule) the action `interval` after the LAST signal.
  public func signal() {
    queue.async { [self] in
      pending?.cancel()
      let item = DispatchWorkItem { [action] in action() }
      pending = item
      queue.asyncAfter(deadline: .now() + interval, execute: item)
    }
  }

  /// Drop any pending fire.
  /// Owners must call this on teardown — a pending fire does not retain the debouncer but WILL still execute up to `interval` after release otherwise.
  public func cancel() {
    queue.async { [self] in
      pending?.cancel()
      pending = nil
    }
  }
}
