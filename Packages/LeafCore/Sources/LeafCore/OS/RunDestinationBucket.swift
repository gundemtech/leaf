import Foundation

/// Phase Track-6 P2 — bucketed enum for Xcode active run destination.
///
/// Raw device names (e.g. `"Dmitrii's iPhone"`) MUST NOT be stored in events;
/// the bucketing function reduces them to one of these enum values BEFORE the
/// value reaches `RawEvent.payload`. See P2 spec §4.6 + §8.
///
/// Raw values are the canonical wire format consumed by `ActivityFeedMapper`
/// and surfaced in `payload.run_destination_bucket`. Renaming any case is a
/// breaking change to the on-wire event schema — bump a migration if needed.
public enum RunDestinationBucket: String, Sendable, Hashable {
    case macos              = "macos"
    case iosSimulator       = "ios_simulator"
    case iosDevice          = "ios_device"
    case tvSimulator        = "tv_simulator"
    case tvDevice           = "tv_device"
    case watchSimulator     = "watch_simulator"
    case watchDevice        = "watch_device"
    case visionSimulator    = "vision_simulator"
    case visionDevice       = "vision_device"
    case unknown            = "unknown"

    /// Heuristic mapper from AppleScript `active run destination.name` raw value
    /// to a bucket. Ordered most-specific-first: the `(Simulator)` suffix must
    /// beat the device-family heuristic so `"iPhone 15 (Simulator)"` →
    /// `.iosSimulator`, not `.iosDevice`.
    ///
    /// The raw input is read inside the parser layer; this function is the
    /// LAST place that string is allowed to live. Once it returns, callers
    /// must drop the raw value.
    public static func bucket(rawName: String?) -> RunDestinationBucket {
        guard let raw = rawName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw != "(none)" else { return .unknown }

        let isSim = raw.contains("(Simulator)") || raw.hasSuffix("Simulator")

        // Exact-match Mac destinations. Substring `contains("My Mac")` would
        // capture "My Macbook Pro" or similar third-party renamings — defend
        // against custom Xcode destination names by requiring exact tokens.
        if raw == "My Mac" || raw == "Any Mac" || raw == "My Mac (Designed for iPad)" {
            return .macos
        }
        if raw.contains("Vision") { return isSim ? .visionSimulator : .visionDevice }
        if raw.contains("Apple Watch") { return isSim ? .watchSimulator : .watchDevice }
        if raw.contains("Apple TV") { return isSim ? .tvSimulator : .tvDevice }
        if raw.contains("iPhone") || raw.contains("iPad") {
            return isSim ? .iosSimulator : .iosDevice
        }
        return .unknown
    }
}
