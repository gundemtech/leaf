//
//  RefreshFreshness.swift
//  LeafCore
//
//  Pure freshness predicate shared by @Observable readers that want a
//  staleness window on refresh() — skip redundant work when a successful
//  result landed less than `window` ago. No I/O, no state: the caller owns
//  the `lastRefreshedAt` timestamp and the clock. Mirrors the inline idiom
//  in LinearTeamsReader (`lastFetchedAt` + `ttl`), extracted so app-target
//  readers (which have no unit-test harness) can be covered in LeafCore.
//

import Foundation

public enum RefreshFreshness {
  /// A result captured at `lastRefreshedAt` is fresh iff it lies strictly
  /// within `window` of `now`. A nil timestamp (no prior successful load)
  /// is never fresh, so the first refresh always proceeds. The boundary
  /// (`now - lastRefreshedAt == window`) is not fresh (strict `<`); a
  /// `window` of 0 is therefore never fresh.
  ///
  /// A negative delta (a `lastRefreshedAt` in the future of `now`, e.g. the
  /// wall clock jumped backwards) is treated as fresh — the result is, by the
  /// `< window` test, "recent". This is intentional and harmless for the 5s
  /// UI debounce: at worst it throttles one extra ambient refresh.
  public static func isFresh(lastRefreshedAt: Date?, now: Date, window: TimeInterval) -> Bool {
    guard let lastRefreshedAt else { return false }
    return now.timeIntervalSince(lastRefreshedAt) < window
  }
}
