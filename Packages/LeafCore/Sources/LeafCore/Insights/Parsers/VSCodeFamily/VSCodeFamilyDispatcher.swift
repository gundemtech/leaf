import Foundation

/// Track-6 P6 — routes a window title to the correct VSCode-fork parser
/// based on bundle ID. Centralizes the bundle-ID → parser-type mapping so
/// `AttentionEmissionPlanner` (and tests) have one entry point.
public enum VSCodeFamilyDispatcher {
    /// Bundle IDs handled by the VSCode-family parser set.
    public static let supportedBundleIDs: Set<String> = [
        VSCodeStableParser.bundleID,
        CursorParser.bundleID,
        VSCodeInsidersParser.bundleID,
        VSCodiumParser.bundleID
    ]

    public static func isVSCodeFamily(bundleID: String) -> Bool {
        supportedBundleIDs.contains(bundleID)
    }

    /// Dispatch parse to the parser matching `bundleID`. Returns nil if
    /// bundle is unknown OR the matching parser returned nil (= caller
    /// emits `ide_window_title_observed` fallback).
    public static func parse(bundleID: String, title: String) -> VSCodeObservation? {
        switch bundleID {
        case VSCodeStableParser.bundleID:    return VSCodeStableParser.parse(title)
        case CursorParser.bundleID:          return CursorParser.parse(title)
        case VSCodeInsidersParser.bundleID:  return VSCodeInsidersParser.parse(title)
        case VSCodiumParser.bundleID:        return VSCodiumParser.parse(title)
        default:                             return nil
        }
    }
}
