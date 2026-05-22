//
//  RetryPolicy.swift
//  LeafCore
//
//  Phase M-I (optimization-tier-m.md). Pure value types + classifier
//  function for SupabaseClient's transient-failure retry wrapper.
//  No I/O, no Date(), trivially testable. Used by SupabaseClient+Retry.
//

import Foundation

public struct RetryPolicy: Sendable, Equatable {
  /// Total attempts including the first. `4` = initial + 3 retries.
  public let maxAttempts: Int
  /// Pre-attempt delays. `delays[i]` = wait BEFORE attempt `i+1`.
  /// Caller guarantees `delays.count >= maxAttempts - 1`.
  public let delays: [Duration]
  /// Jitter band as a fraction of each delay. `0.25` = ±25%.
  public let jitterFraction: Double

  public init(maxAttempts: Int, delays: [Duration], jitterFraction: Double) {
    self.maxAttempts = maxAttempts
    self.delays = delays
    self.jitterFraction = jitterFraction
  }

  public static let `default` = RetryPolicy(
    maxAttempts: 4,
    delays: [.milliseconds(200), .seconds(1), .seconds(3)],
    jitterFraction: 0.25
  )
}

public enum RetryDecision: Sendable, Equatable {
  case giveUp
  case retry(after: Duration)
}

/// Pure decision. No I/O. All inputs explicit so tests can pin every branch.
///
/// - Parameters:
///   - response: the HTTP response if the request completed (nil if URLError thrown).
///   - error: the URLError if URLSession threw (nil if response received).
///   - attempt: 0-indexed attempt counter BEFORE incrementing (so attempt=0 is the first try).
///   - policy: retry budget + schedule + jitter band.
///   - retryAfterHint: already-parsed server hint (header OR body field). Applied verbatim,
///     no jitter, for 429 paths only. Pass nil otherwise.
///   - nextDelayJitterMultiplier: `1.0 + rand(-jitterFraction, +jitterFraction)`. Injected
///     by caller (or test) for determinism.
public func classify(
  response: HTTPURLResponse?,
  error: URLError?,
  attempt: Int,
  policy: RetryPolicy,
  retryAfterHint: Duration?,
  nextDelayJitterMultiplier: Double
) -> RetryDecision {
  // Budget guard: if we've already used the last attempt, give up before
  // inspecting anything else. Caller is responsible for not calling us
  // when the request succeeded with a 2xx — we'd return .giveUp here too.
  if attempt + 1 >= policy.maxAttempts {
    return .giveUp
  }

  // URLError branch.
  if let error {
    switch error.code {
    case .timedOut,
      .networkConnectionLost,
      .notConnectedToInternet,
      .dnsLookupFailed,
      .cannotConnectToHost,
      .cannotFindHost:
      return .retry(
        after: scaledDelay(at: attempt, policy: policy, multiplier: nextDelayJitterMultiplier))
    default:
      // .cancelled, .secureConnectionFailed, .badServerResponse, etc.
      return .giveUp
    }
  }

  // HTTP branch.
  guard let response else { return .giveUp }
  let code = response.statusCode

  if code == 429 {
    if let hint = retryAfterHint {
      return .retry(after: hint)  // verbatim, no jitter
    }
    return .retry(
      after: scaledDelay(at: attempt, policy: policy, multiplier: nextDelayJitterMultiplier))
  }

  if code == 501 {
    return .giveUp  // Not Implemented = permanent
  }

  if (500...599).contains(code) {
    return .retry(
      after: scaledDelay(at: attempt, policy: policy, multiplier: nextDelayJitterMultiplier))
  }

  // 2xx, 3xx, 4xx (incl. 401, 403, 404, 409, 410, 422) — permanent.
  return .giveUp
}

private func scaledDelay(at attempt: Int, policy: RetryPolicy, multiplier: Double) -> Duration {
  let base = policy.delays[min(attempt, policy.delays.count - 1)]
  // Duration arithmetic via DoubleSeconds round-trip — tolerable precision
  // for backoff delays (millisecond-level accuracy is plenty).
  let baseSeconds =
    Double(base.components.seconds) + Double(base.components.attoseconds) / 1e18
  let scaled = baseSeconds * multiplier
  return .milliseconds(Int(scaled * 1000))
}
