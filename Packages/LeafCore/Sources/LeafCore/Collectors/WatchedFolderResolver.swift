import Foundation

/// Settings dead-toggle remediation (WS1) — resolves a tilde-prefixed workspace
/// path (`~/...`) to the id of the enabled watched folder that contains it, or nil.
///
/// Shared by the IDE FSEvents watchers (VSCode / JetBrains). It is the only
/// path→watchedFolderID matcher in public LeafCore — `FSEventsRouterProd`'s
/// matcher is moat-private and operates on canonical absolute paths, whereas the
/// watchers hand us tilde-prefixed sanitized paths (privacy: never a bare
/// `/Users/<name>/...` in the emitted payload).
public enum WatchedFolderResolver {
    /// `tildePath` is `~`, `~/...`, or an absolute `/...`. Returns the id of the
    /// first *enabled* watched folder whose canonical path equals or is a parent
    /// of `tildePath`; nil if none (or the input is not a path).
    public static func resolveID(
        tildePath: String,
        in folders: [WatchedFolder],
        homeDir: String = NSHomeDirectory()
    ) -> String? {
        let absolute: String
        if tildePath == "~" {
            absolute = homeDir
        } else if tildePath.hasPrefix("~/") {
            absolute = homeDir + String(tildePath.dropFirst(1))  // drop "~", keep "/…"
        } else if tildePath.hasPrefix("/") {
            absolute = tildePath
        } else {
            return nil  // not a tilde/absolute path — cannot match a folder
        }
        for folder in folders where folder.enabled {
            // Tolerate a trailing slash on the stored folder path; the `+ "/"`
            // guard prevents sibling false positives (".../Leaf" vs ".../LeafOther").
            let fp = folder.path.hasSuffix("/") ? String(folder.path.dropLast()) : folder.path
            if absolute == fp || absolute.hasPrefix(fp + "/") {
                return folder.id
            }
        }
        return nil
    }
}
