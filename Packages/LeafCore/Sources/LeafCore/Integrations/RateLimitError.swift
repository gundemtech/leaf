import Foundation

/// Phase Track-1 D1 — generic rate-limit error type. Slack provider throws
/// `.retryAfter(seconds)` from 429 responses with `Retry-After` header.
/// Collector handles by logging + breaking fan-out loop, advancing cursor
/// only on success. Linear / GitHub providers use their own graceful-degrade
/// patterns (return empty / nil on 429) and do not throw this type.
public enum RateLimitError: Error, Sendable {
    case retryAfter(Int)
}
