import Foundation

/// Thrown by `withTimeout` when the deadline elapses before `operation` finishes.
public struct TimeoutError: Error, Sendable {
  public let duration: Duration
  public init(duration: Duration) { self.duration = duration }
}

/// Runs `operation` with an upper time bound. If `operation` finishes first its
/// result (or thrown error) propagates; if the `duration` deadline wins,
/// `TimeoutError` is thrown and the operation Task is cancelled.
///
/// Used to bound UI-facing network refreshes so a stalled request (slow server,
/// wedged auth bootstrap, retry-loop backoff) can't pin a `.loading` spinner
/// indefinitely — the reader transitions to `.error` instead. The operation
/// must honour Task cancellation for the cancel to take effect; URLSession's
/// async API and `Task.sleep` both do, so the orphaned request unwinds promptly.
public func withTimeout<T: Sendable>(
  _ duration: Duration,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw TimeoutError(duration: duration)
    }
    // Whichever child finishes first decides the outcome; cancel the loser
    // (the pending network request, or the sleep) on the way out.
    defer { group.cancelAll() }
    guard let result = try await group.next() else {
      throw TimeoutError(duration: duration)
    }
    return result
  }
}
