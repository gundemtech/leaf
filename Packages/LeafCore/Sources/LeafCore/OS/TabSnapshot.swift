// Packages/LeafCore/Sources/LeafCore/OS/TabSnapshot.swift
import Foundation

/// Phase Track-6 P3 — per-tab descriptor carrying stable key + raw title +
/// raw URL. Adapter wrapper filters URL via `applyGranularity` BEFORE
/// passing snapshots into state machines. See spec §3.2 + §7.4.
///
/// `tabKey`:
///   - Chrome / Arc: stable `tab.id` from AppleScript dictionary.
///   - Safari: positional `"i<index>"` (Safari's AS dictionary lacks a
///     stable per-tab id; positional key is lossy on tab close + reindex).
public struct TabSnapshot: Sendable, Hashable, Codable {
    public let tabKey: String
    public let title: String
    public let url: String

    public init(tabKey: String, title: String, url: String) {
        self.tabKey = tabKey
        self.title = title
        self.url = url
    }
}
