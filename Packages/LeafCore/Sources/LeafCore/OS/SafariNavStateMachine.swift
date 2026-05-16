// Packages/LeafCore/Sources/LeafCore/OS/SafariNavStateMachine.swift
import Foundation

/// Phase Track-6 P3 — per-tab URL diff for Safari (positional `tabKey`).
/// See spec §7.2.
public struct SafariNavStateMachine: Sendable {
    private static let bundleID = "com.apple.Safari"
    private var prevTabUrls: [String: String]?

    public init() {}

    public mutating func observe(
        snapshots: [TabSnapshot],
        windowID: String?,
        nowMs: Int64
    ) -> [ProtoBrowserEvent] {
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
