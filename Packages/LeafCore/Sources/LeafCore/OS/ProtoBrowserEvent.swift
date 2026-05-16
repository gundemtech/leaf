// Packages/LeafCore/Sources/LeafCore/OS/ProtoBrowserEvent.swift
import Foundation

/// Phase Track-6 P3 — intermediate emit type from per-browser state
/// machines. Adapter wrapper maps 1:1 to `RawEvent`. URLs/titles already
/// filtered by adapter before state machine saw them, so this carries
/// only filter-allowed values.
public enum ProtoBrowserEvent: Sendable {
    case tabNavigated(
        bundleID: String,
        tabKey: String,
        previousURL: String,
        currentURL: String,
        title: String,
        activeWindowID: String?,
        nowMs: Int64
    )
    case tabActivated(
        bundleID: String,
        previousTabKey: String,
        currentTabKey: String,
        currentURL: String,
        title: String,
        activeWindowID: String?,
        nowMs: Int64
    )
}
