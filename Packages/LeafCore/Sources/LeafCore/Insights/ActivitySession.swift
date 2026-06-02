//
//  ActivitySession.swift
//  LeafCore
//
//  Phase 4.10.B — aggregated work session derived from `attention` events
//  (+ `context` boundary markers) by `SessionFeedMapper`. Covers the case
//  "what was I doing in Xcode over the last 3 hours": one row = one continuous
//  block of work in (bundle, window/url) with a duration.
//
//  The `bundleID` field is stored raw; the UI resolves a human-readable name via
//  `AppNameResolver` at the presentation layer (same pattern as
//  `ActivityFeedEntry`). This keeps the model free of AppKit.
//

import Foundation

/// One block of continuous work in a single (application, window/URL).
///
/// Identity = id of the session's first attention event. This gives a stable key for
/// SwiftUI ForEach and an easy way to reference the raw event for later
/// drill-downs (should they ever be needed).
public struct ActivitySession: Identifiable, Sendable, Hashable {
    /// id of the session's first attention event. Stable SwiftUI identity.
    public let id: Int64

    /// Bundle identifier of the application (`com.apple.dt.Xcode`).
    public let bundleID: String

    /// Category for the colored dot in the UI (dev/browse/communication/design/other).
    public let category: AppCategory

    /// Row subtitle — the focused window title or browser URL.
    /// `nil` when AX permission is not granted or the granularity ceiling = L1.
    public let contextLabel: String?

    /// Session start — timestamp of the first attention event.
    public let start: Date

    /// Session end. The semantics depend on how the session was closed:
    ///   * closed by a switch → end = ts of the next event (no gap).
    ///   * closed by idle context → end = ts of the idle event.
    ///   * closed by timeout (gap > threshold) → end = `lastEventTs + gap`.
    ///   * trailing (last in the selection) → end = `min(lastEventTs + gap, refEnd)`.
    public let end: Date

    /// How many raw attention events collapsed into this session (polls +
    /// app-switches with the same (bundle, contextLabel)).
    public let eventCount: Int

    public init(
        id: Int64,
        bundleID: String,
        category: AppCategory,
        contextLabel: String?,
        start: Date,
        end: Date,
        eventCount: Int
    ) {
        self.id = id
        self.bundleID = bundleID
        self.category = category
        self.contextLabel = contextLabel
        self.start = start
        self.end = end
        self.eventCount = eventCount
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}
