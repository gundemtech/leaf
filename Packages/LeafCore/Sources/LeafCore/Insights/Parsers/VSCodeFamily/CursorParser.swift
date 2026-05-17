import Foundation

/// Track-6 P6 — Cursor (vscode fork distributed via ToDesktop) title parser.
/// Bundle ID confirmed via Cursor Community Forum.
public enum CursorParser: VSCodeFamilyTitleParser {
    public static let bundleID = "com.todesktop.230313mzl4w4u92"
    public static let appNameLiteral = "Cursor"

    public static func parse(_ title: String) -> VSCodeObservation? {
        guard
            let obs = VSCodeFamilyParseHelper.parseDefaultFormat(
                title,
                bundleID: bundleID,
                appNameRegexLiteral: appNameLiteral
            )
        else { return nil }
        return VSCodeObservation(
            ideBundleID: obs.ideBundleID,
            workspaceName: VSCodeFamilyParseHelper.stripSSHPrefix(obs.workspaceName),
            fileBasename: obs.fileBasename
        )
    }
}
