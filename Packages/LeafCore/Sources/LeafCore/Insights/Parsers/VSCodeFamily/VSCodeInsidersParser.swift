import Foundation

/// Track-6 P6 — VSCode Insiders (beta channel) title parser.
/// Title format includes hyphen in ${appName}: "Visual Studio Code - Insiders".
/// Custom segment parse because helper's hyphen-fallback would over-split.
public enum VSCodeInsidersParser: VSCodeFamilyTitleParser {
    public static let bundleID = "com.microsoft.VSCodeInsiders"
    public static let appNameLiteral = "Visual Studio Code - Insiders"

    public static func parse(_ title: String) -> VSCodeObservation? {
        var work = title
        if work.hasPrefix("● ") { work.removeFirst(2) }
        if work.hasPrefix("●") { work.removeFirst() }
        work = work.trimmingCharacters(in: .whitespacesAndNewlines)

        // Insiders always renders with em-dash separator " — " for activeEditor/
        // rootName segments. Tail is literal "Visual Studio Code - Insiders".
        guard work.hasSuffix(" — \(appNameLiteral)") else { return nil }
        let head = String(work.dropLast(" — \(appNameLiteral)".count))
        let trimmedHead = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHead.isEmpty else { return nil }

        let segments = trimmedHead.components(separatedBy: " — ").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch segments.count {
        case 2:
            // file — workspace
            guard !segments[0].isEmpty, !segments[1].isEmpty else { return nil }
            return VSCodeObservation(
                ideBundleID: bundleID,
                workspaceName: VSCodeFamilyParseHelper.stripSSHPrefix(segments[1]),
                fileBasename: segments[0]
            )
        case 1:
            // single-file mode: file only
            guard !segments[0].isEmpty else { return nil }
            return VSCodeObservation(
                ideBundleID: bundleID,
                workspaceName: nil,
                fileBasename: segments[0]
            )
        default:
            return nil
        }
    }
}
