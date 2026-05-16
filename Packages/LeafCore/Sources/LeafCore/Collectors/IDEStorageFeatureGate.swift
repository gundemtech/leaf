import Foundation

/// Track-6 P6 — feature gate protocol for IDE-storage FSEvents watchers
/// (VSCodeWorkspaceWatcher, JetBrainsRecentProjectsWatcher). Mirrors P3
/// BrowserBookmarksFeatureGate pattern. Default both OFF per ADR-020 +
/// Track-4 S3 posture.
public protocol IDEStorageFeatureGate: Sendable {
    var vscodeStorageEnabled: Bool { get async }
    var jetbrainsStorageEnabled: Bool { get async }
}

/// Always-OFF fallback for tests / preview / bootstrap before
/// LocalAppsStore is wired.
public struct DisabledIDEStorageFeatureGate: IDEStorageFeatureGate {
    public init() {}
    public var vscodeStorageEnabled: Bool { false }
    public var jetbrainsStorageEnabled: Bool { false }
}
