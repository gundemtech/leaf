// Packages/LeafCore/Sources/LeafCore/OS/ArcActiveStateMachine.swift
import Foundation

/// Phase Track-6 P3 — front-window active-tab diff for Arc. See spec §7.3.
public struct ArcActiveStateMachine: Sendable {
    private static let bundleID = "company.thebrowser.Browser"
    private var prev: (windowID: String, tabKey: String)?

    public init() {}

    public mutating func observe(
        currentTabKey: String,
        currentURL: String,
        title: String,
        windowID: String?,
        nowMs: Int64
    ) -> [ProtoBrowserEvent] {
        let prevSnap = prev
        defer {
            if let wid = windowID {
                prev = (wid, currentTabKey)
            }
        }
        guard let p = prevSnap, let wid = windowID else { return [] }
        guard p.windowID != wid || p.tabKey != currentTabKey else { return [] }
        return [
            .tabActivated(
                bundleID: Self.bundleID,
                previousTabKey: p.tabKey,
                currentTabKey: currentTabKey,
                currentURL: currentURL,
                title: title,
                activeWindowID: wid,
                nowMs: nowMs
            )
        ]
    }
}
