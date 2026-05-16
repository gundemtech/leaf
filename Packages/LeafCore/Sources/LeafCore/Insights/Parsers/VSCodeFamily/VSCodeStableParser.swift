import Foundation

/// Track-6 P6 — VSCode stable build title parser.
/// Title format (vendor docs, v1.108+):
///   ${dirty}${activeEditorShort} — ${rootName} — Visual Studio Code
public enum VSCodeStableParser: VSCodeFamilyTitleParser {
    public static let bundleID = "com.microsoft.VSCode"
    public static let appNameLiteral = "Visual Studio Code"

    public static func parse(_ title: String) -> VSCodeObservation? {
        guard let obs = VSCodeFamilyParseHelper.parseDefaultFormat(
            title,
            bundleID: bundleID,
            appNameRegexLiteral: appNameLiteral
        ) else {
            return nil
        }
        return VSCodeObservation(
            ideBundleID: obs.ideBundleID,
            workspaceName: VSCodeFamilyParseHelper.stripSSHPrefix(obs.workspaceName),
            fileBasename: obs.fileBasename
        )
    }
}
