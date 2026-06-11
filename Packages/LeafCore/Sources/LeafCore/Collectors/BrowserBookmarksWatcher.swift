import Foundation
import CoreServices
import OSLog

// MARK: - Protocols

/// Phase Track-6 P3 — narrow batch write interface for the bookmarks watcher.
/// `Database` already conforms via its existing `func write(_ events: [RawEvent]) throws`.
/// Tests provide an in-memory stub (`MockBookmarkWriter`).
public protocol BookmarkEventBatchWriter: Sendable {
    func write(_ events: [RawEvent]) throws
}

/// Phase Track-6 P3 — feature gate that controls whether Chrome / Safari bookmark
/// FSEvent streams run. Backed by `LocalAppsStore` sub-field toggles in production;
/// a simple struct in tests. Both streams are OFF by default (opt-in discipline).
///
/// `LocalAppsStore` lives in LeafCore and is `Sendable`, so production conformance
/// requires no extra bridging — the Agent creates a `LocalAppsStore` and passes it
/// directly (via the `BrowserBookmarksFeatureGate` protocol) to avoid leaking the
/// full `LocalAppsStore` API into this actor's signature.
public protocol BrowserBookmarksFeatureGate: Sendable {
    var chromeEnabled: Bool { get }
    var safariEnabled: Bool { get }
}

extension Database: BookmarkEventBatchWriter {
    // Satisfy protocol by forwarding to the existing `write(_:knownLinearPrefixes:derivers:)`
    // overload (protocol witness requires exact signature). `nil` defers to the
    // instance-level `EventDerivationConfig` (Track A0).
    public func write(_ events: [RawEvent]) throws {
        try write(events, knownLinearPrefixes: nil, derivers: nil)
    }
}

// MARK: - Actor

/// Phase Track-6 P3 — independent FSEvents-backed bookmark count watcher.
/// Owns its own FSEventStream per browser; recursive watch with filename
/// suffix filter. Spec §8.
///
/// Chrome: multi-profile, counter keyed by profile label (last path component
/// of the profile directory). Each profile is tracked independently.
///
/// Safari: single counter, gated on Full Disk Access (`fdaGranted`).
/// If FDA is not granted at `init` time, Safari events are silently skipped.
///
/// Semantics (cold/warm tick):
///   - First FSEvent for a given profile seeds the counter; no emit.
///   - Subsequent events compute delta (may be 0 for renames); always emit.
///
/// Feature gate: both Chrome and Safari streams only start when the corresponding
/// `featureGate.chromeEnabled` / `featureGate.safariEnabled` flag is true.
/// Toggles in Settings have no runtime effect until Agent restart (v1 constraint).
/// TODO(v1.1): observe a darwin notification on toggle-flip and call `refresh()`.
public actor BrowserBookmarksWatcher {
    public typealias ChromeCountProbe = @Sendable (_ profileLabel: String) -> Int?
    public typealias SafariCountProbe = @Sendable (_ path: String) -> Int?

    private let writer: any BookmarkEventBatchWriter
    private let chromeCountProbe: ChromeCountProbe
    private let safariCountProbe: SafariCountProbe
    private let fdaGranted: Bool
    private let featureGate: any BrowserBookmarksFeatureGate

    private var chromeCounts: [String: Int] = [:]
    private var safariCount: Int? = nil

    private var chromeStream: FSEventStream?
    private var safariStream: FSEventStream?

    public init(
        writer: any BookmarkEventBatchWriter,
        chromeCountProbe: @escaping ChromeCountProbe,
        safariCountProbe: @escaping SafariCountProbe,
        fdaGranted: Bool,
        featureGate: any BrowserBookmarksFeatureGate
    ) {
        self.writer = writer
        self.chromeCountProbe = chromeCountProbe
        self.safariCountProbe = safariCountProbe
        self.fdaGranted = fdaGranted
        self.featureGate = featureGate
    }

    // MARK: - Lifecycle

    public func start() async {
        let chromeRoot = NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
        if featureGate.chromeEnabled && FileManager.default.fileExists(atPath: chromeRoot) {
            chromeStream = try? FSEventStream(
                paths: [chromeRoot],
                latency: 1.5,
                queueLabel: "tech.gundem.leaf.fsevents.chromebookmarks"
            ) { [weak self] paths, _ in
                guard let self else { return }
                for path in paths where path.hasSuffix("/Bookmarks") {
                    let profile = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    Task { await self.handleChromeEvent(profileLabel: profile, nowMs: now) }
                }
            }
            chromeStream?.start()
        }
        if featureGate.safariEnabled && fdaGranted {
            let safariDir = NSHomeDirectory() + "/Library/Safari"
            safariStream = try? FSEventStream(
                paths: [safariDir],
                latency: 1.5,
                queueLabel: "tech.gundem.leaf.fsevents.safaribookmarks"
            ) { [weak self] paths, _ in
                guard let self else { return }
                for path in paths where path.hasSuffix("/Bookmarks.plist") {
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    Task { await self.handleSafariEvent(nowMs: now) }
                }
            }
            safariStream?.start()
        }
    }

    public func stop() async {
        chromeStream?.stop(); chromeStream = nil
        safariStream?.stop(); safariStream = nil
    }

    // MARK: - Event handlers (visible for tests)

    public func handleChromeEvent(profileLabel: String, nowMs: Int64) {
        // Defense-in-depth: drop events that arrive when toggle is off (e.g.
        // if toggle flipped after `start()` and before `stop()` tears the stream).
        guard featureGate.chromeEnabled else { return }
        guard let newCount = chromeCountProbe(profileLabel) else { return }
        let prev = chromeCounts[profileLabel]
        // MINOR-1: write counter AFTER guard so cold-tick seed reads clearly.
        // (Spec §8.3: seed → no emit; subsequent → emit delta.)
        guard let prev else {
            chromeCounts[profileLabel] = newCount   // cold tick — seed only, no emit
            return
        }
        chromeCounts[profileLabel] = newCount
        try? writer.write([makeEvent(
            bundleID: "com.google.Chrome",
            eventKind: "chrome_bookmark_changed",
            totalCount: newCount,
            delta: newCount - prev,
            profileLabel: profileLabel,
            nowMs: nowMs
        )])
    }

    public func handleSafariEvent(nowMs: Int64) {
        // Defense-in-depth: drop events when toggle is off.
        guard featureGate.safariEnabled else { return }
        guard fdaGranted else { return }
        let safariPath = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
        guard let newCount = safariCountProbe(safariPath) else { return }
        let prev = safariCount
        // MINOR-1: write counter AFTER guard (mirror Chrome handler).
        guard let prev else {
            safariCount = newCount   // cold tick — seed only, no emit
            return
        }
        safariCount = newCount
        try? writer.write([makeEvent(
            bundleID: "com.apple.Safari",
            eventKind: "safari_bookmark_changed",
            totalCount: newCount,
            delta: newCount - prev,
            profileLabel: nil,
            nowMs: nowMs
        )])
    }

    // MARK: - Private helpers

    private func makeEvent(
        bundleID: String,
        eventKind: String,
        totalCount: Int,
        delta: Int,
        profileLabel: String?,
        nowMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "event_kind": eventKind,
            "total_count": String(totalCount),
            "delta": String(delta)
        ]
        if let p = profileLabel {
            payload["profile_label"] = p
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
            signalType: .context,
            bundleID: bundleID,
            payload: payload
        )
    }
}
