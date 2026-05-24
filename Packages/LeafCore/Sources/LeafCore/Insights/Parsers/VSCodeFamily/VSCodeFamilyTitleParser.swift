import Foundation

/// Track-6 P6 — protocol implemented by each vscode-fork title parser.
/// Per Q8c (research §11.1): one file per fork so vendor-specific edge
/// cases can diverge without growing the shared helper.
public protocol VSCodeFamilyTitleParser: Sendable {
    /// Bundle ID this parser targets.
    static var bundleID: String { get }

    /// Fork's `${appName}` value as it appears in the title's tail segment.
    /// Examples: "Visual Studio Code" / "Cursor" / "Visual Studio Code - Insiders"
    /// / "VSCodium". Used by `parseDefaultFormat` regex builder.
    static var appNameLiteral: String { get }

    /// Parse a window title. Returns nil if the title does not match any
    /// known shape — caller (`AttentionEmissionPlanner`) then emits the
    /// `ide_window_title_observed` fallback event_kind.
    static func parse(_ title: String) -> VSCodeObservation?
}

/// Shared regex helper for the default vscode `window.title` shape:
///
///   ${dirty}${activeEditorShort} — ${rootName} — ${appName}
///   ${dirty}${activeEditorShort} — ${appName}     (single-file mode)
///
/// Em-dash (—) is default for VSCode stable; hyphen (-) for some forks.
/// Helper accepts either. Returns (file_basename, workspace_name) — workspace
/// nil when single-file-mode regex matches.
public enum VSCodeFamilyParseHelper {
    public static func parseDefaultFormat(
        _ title: String,
        bundleID: String,
        appNameRegexLiteral: String
    ) -> VSCodeObservation? {
        // Strip leading dirty marker "● " if present.
        var work = title
        if work.hasPrefix("● ") { work.removeFirst(2) }
        if work.hasPrefix("●") { work.removeFirst() }
        work = work.trimmingCharacters(in: .whitespacesAndNewlines)

        // Split on " — " (em-dash with spaces) first, fall back to " - " (hyphen).
        let segments: [String]
        if work.contains(" — ") {
            segments = work.components(separatedBy: " — ")
        } else if work.contains(" - ") {
            segments = work.components(separatedBy: " - ")
        } else {
            return nil
        }

        let trimmed = segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Tail must match appNameLiteral. Tail can equal the literal verbatim
        // OR include the literal as a substring (e.g. "Visual Studio Code -
        // Insiders" matches "Visual Studio Code - Insiders" exactly when split
        // on " - " yields ["Visual Studio Code", "Insiders"] — Insiders parser
        // overrides default-format with custom regex; this helper handles only
        // single-segment appName).
        guard let tail = trimmed.last, tail == appNameRegexLiteral else { return nil }

        switch trimmed.count {
        case 3:
            // file — workspace — appName
            let file = trimmed[0]
            let workspace = trimmed[1]
            guard !file.isEmpty, !workspace.isEmpty else { return nil }
            return VSCodeObservation(
                ideBundleID: bundleID,
                workspaceName: workspace,
                fileBasename: file
            )
        case 2:
            // Single-file mode: file — appName (no workspace)
            let file = trimmed[0]
            guard !file.isEmpty else { return nil }
            return VSCodeObservation(
                ideBundleID: bundleID,
                workspaceName: nil,
                fileBasename: file
            )
        default:
            return nil
        }
    }

    /// SSH-prefix strip for `${rootName}` of remote workspaces.
    /// VSCode renders remote workspace root as "[SSH: hostname] reponame".
    public static func stripSSHPrefix(_ workspace: String?) -> String? {
        guard let w = workspace else { return nil }
        if let range = w.range(of: #"^\[SSH:[^\]]+\]\s+"#, options: .regularExpression) {
            return String(w[range.upperBound...])
        }
        return w
    }
}
