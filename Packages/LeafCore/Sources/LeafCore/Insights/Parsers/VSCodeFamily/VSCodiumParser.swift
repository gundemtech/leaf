import Foundation

/// Track-6 P6 — VSCodium (vscode OSS distribution) title parser.
/// Bundle ID `com.visualstudio.code.oss` already in ProdAppCategoryClassifier.dev
/// (research §11.2 Stage 1 verified). Some builds render appName as
/// "Codium", others as "VSCodium" — parser tries both.
public enum VSCodiumParser: VSCodeFamilyTitleParser {
    public static let bundleID = "com.visualstudio.code.oss"
    public static let appNameLiteral = "VSCodium"

    public static func parse(_ title: String) -> VSCodeObservation? {
        for literal in ["VSCodium", "Codium"] {
            if let obs = VSCodeFamilyParseHelper.parseDefaultFormat(
                title,
                bundleID: bundleID,
                appNameRegexLiteral: literal
            ) {
                return VSCodeObservation(
                    ideBundleID: obs.ideBundleID,
                    workspaceName: VSCodeFamilyParseHelper.stripSSHPrefix(obs.workspaceName),
                    fileBasename: obs.fileBasename
                )
            }
        }
        return nil
    }
}
