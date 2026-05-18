import Foundation

public enum IDEFamily: String, Sendable, Equatable {
    case vscodeFamily
    case jetbrains
    case fallback
}

public enum IDEFamilyClassifier {
    /// 13 standard publicly-documented JetBrains macOS bundle IDs
    /// (architecture.md "JetBrains bundle list 13 (−AppCode,
    /// +DataGrip/RustRover/DataSpell)"). Exposed for re-use by future
    /// filters / detail-screen rollups.
    public static let jetbrainsBundleIDs: Set<String> = [
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.goland",
        "com.jetbrains.CLion",
        "com.jetbrains.rubymine",
        "com.google.android.studio",
        "com.jetbrains.datagrip",
        "com.jetbrains.rustrover",
        "com.jetbrains.dataspell",
    ]

    public static func family(forBundleID id: String) -> IDEFamily {
        if VSCodeFamilyDispatcher.isVSCodeFamily(bundleID: id) {
            return .vscodeFamily
        }
        if jetbrainsBundleIDs.contains(id) {
            return .jetbrains
        }
        return .fallback
    }
}
