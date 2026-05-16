// Packages/LeafCore/Sources/LeafCore/OS/ArcNavStateMachine.swift
import Foundation

/// Phase Track-6 P3 — per-tab URL diff for Arc (opaque string `tabKey` from AppleScript `tab.id`).
/// Graceful-degrade: empty snapshots array leaves prevTabUrls unchanged (no emit, no state reset).
/// See spec §7.2.
public struct ArcNavStateMachine: Sendable {
    private static let bundleID = "company.thebrowser.Browser"
    private var prevTabUrls: [String: String]?

    public init() {}

    public mutating func observe(
        snapshots: [TabSnapshot],
        windowID: String?,
        nowMs: Int64
    ) -> [ProtoBrowserEvent] {
        // Graceful degrade: Arc AS dictionary can return empty on partial failure.
        // Preserve previous state; emit nothing rather than spurious closes.
        guard !snapshots.isEmpty else { return [] }
        let nextMap = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.tabKey, $0.url) })
        defer { prevTabUrls = nextMap }
        guard let prev = prevTabUrls else { return [] }
        var emits: [ProtoBrowserEvent] = []
        for snap in snapshots {
            guard let prevURL = prev[snap.tabKey], prevURL != snap.url else { continue }
            emits.append(.tabNavigated(
                bundleID: Self.bundleID,
                tabKey: snap.tabKey,
                previousURL: prevURL,
                currentURL: snap.url,
                title: snap.title,
                activeWindowID: windowID,
                nowMs: nowMs
            ))
        }
        return emits
    }
}
