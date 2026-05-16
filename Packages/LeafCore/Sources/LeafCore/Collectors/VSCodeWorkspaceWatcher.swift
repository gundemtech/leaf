import Foundation

/// Track-6 P6 — FSEvents watcher for VSCode-family `workspaceStorage/<hash>/`
/// directory creation events. On CREATE: loads `workspace.json` (plain
/// JSON, unlocked, atomic write per vscode upstream), URL-decodes
/// `folder` URI, home-dir-sanitizes (`/Users/alice/...` → `~/...`),
/// resolves against `WatchedFolderStore`, emits `vscode_workspace_opened`.
///
/// Privacy walkback at parser boundary:
///   1. URL-decode percent escapes.
///   2. Replace $HOME prefix with `~/`.
///   3. Resolve against watched-folder bookmarks.
///   4. Inside-watched → payload {workspace_name (basename), watched_folder_id, outside_watched_folder=false}.
///   5. Outside-watched → payload {workspace_name (basename only), outside_watched_folder=true}.
///   6. NEVER absolute path in payload (even when watched-folder match).
///
/// TCC: zero new prompt — ~/Library/Application Support/<vendor>/ is
/// outside FDA umbrella (P3 BrowserBookmarksWatcher pattern).
///
/// Cold path: Agent start does NOT replay existing workspaceStorage/<hash>/
/// dirs. Only watch from now — historical dirs are stale-timestamped.
public actor VSCodeWorkspaceWatcher {
    public struct ParsedWorkspace: Equatable {
        public let workspaceName: String
        public let sanitizedPath: String  // ~-prefixed
    }

    /// Vendor-root subdirectory names under `~/Library/Application Support/`
    /// that this watcher targets.
    public static let vendorRoots: [String] = [
        "Code",            // VSCode stable
        "Cursor",          // Cursor (ToDesktop)
        "Code - Insiders", // VSCode Insiders
        "VSCodium"
    ]

    public static func inferBundleID(forVendorRoot root: String) -> String? {
        switch root {
        case "Code":            return VSCodeStableParser.bundleID
        case "Cursor":          return CursorParser.bundleID
        case "Code - Insiders": return VSCodeInsidersParser.bundleID
        case "VSCodium":        return VSCodiumParser.bundleID
        default:                return nil
        }
    }

    /// Parse a `workspace.json` body. Returns nil for malformed JSON or
    /// missing `folder` URI.
    public static func parseWorkspaceJSON(_ body: String, homeDir: String) -> ParsedWorkspace? {
        guard let data = body.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let folderURI = json["folder"] as? String, !folderURI.isEmpty else { return nil }

        // 1. Strip file:// scheme.
        var path = folderURI
        if path.hasPrefix("file://") { path = String(path.dropFirst("file://".count)) }

        // 2. URL-decode percent escapes.
        guard let decoded = path.removingPercentEncoding else { return nil }
        path = decoded

        // 3. Replace home-dir prefix with ~.
        if path.hasPrefix(homeDir + "/") {
            path = "~" + String(path.dropFirst(homeDir.count))
        } else if path == homeDir {
            path = "~"
        }

        // 4. Extract basename (workspace_name).
        let basename: String = {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            return parts.last.map(String.init) ?? trimmed
        }()
        guard !basename.isEmpty else { return nil }

        return ParsedWorkspace(workspaceName: basename, sanitizedPath: path)
    }

    /// Build the RawEvent. NEVER embeds absolute path. `sanitizedPath` arg
    /// is for caller's logging/diagnostics; only `workspaceName` and the
    /// gate fields reach the payload.
    public static func buildEvent(
        bundleID: String,
        workspaceName: String,
        sanitizedPath: String,        // for caller diagnostics only — NOT emitted
        watchedFolderID: String?,
        nowMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "event_kind": "vscode_workspace_opened",
            "ide_bundle_id": bundleID,
            "workspace_name": workspaceName
        ]
        if let id = watchedFolderID {
            payload["watched_folder_id"] = id
            payload["outside_watched_folder"] = "false"
        } else {
            payload["outside_watched_folder"] = "true"
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000.0),
            signalType: .attention,
            bundleID: bundleID,
            payload: payload
        )
    }

    // MARK: - FSEvents runtime

    /// Lifecycle owner. Caller (LeafAgent) constructs with feature-gate +
    /// watched-folder resolver + event sink + clock; `start()` registers
    /// FSEvents streams; `stop()` tears them down.
    ///
    /// Implementation tier (not test-covered at unit level — covered by
    /// integration smoke in Stage 7).
    private let homeDir: String
    private let watchedFolderResolver: (_ path: String) -> String?
    private let eventSink: (RawEvent) -> Void
    private let clock: () -> Int64

    public init(
        homeDir: String = NSHomeDirectory(),
        watchedFolderResolver: @escaping (_ path: String) -> String?,
        eventSink: @escaping (RawEvent) -> Void,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.homeDir = homeDir
        self.watchedFolderResolver = watchedFolderResolver
        self.eventSink = eventSink
        self.clock = clock
    }

    public func start() async {
        // FSEvents stream registration for each vendor-root's workspaceStorage/.
        // Mirror P3 BrowserBookmarksWatcher pattern. Cold path: no replay.
        // (Implementation body uses FSEventStreamCreate + dispatch — see
        // BrowserBookmarksWatcher for reference. Unit-test scope is on
        // parse/build helpers; lifecycle covered by integration smoke.)
        // TODO at Task 14b (separate commit if scope creeps): wire actual
        // FSEvents loop here.
    }

    public func stop() async {
        // Tear down FSEvents streams.
    }

    /// Test hook — exposed for tests to drive a synthetic CREATE event without
    /// real FSEvents.
    public func onWorkspaceStorageDirCreated(
        vendorRoot: String,
        workspaceJSONBody: String
    ) async {
        guard let bundleID = Self.inferBundleID(forVendorRoot: vendorRoot) else { return }
        guard let parsed = Self.parseWorkspaceJSON(workspaceJSONBody, homeDir: homeDir) else { return }
        let watchedID = watchedFolderResolver(parsed.sanitizedPath)
        let event = Self.buildEvent(
            bundleID: bundleID,
            workspaceName: parsed.workspaceName,
            sanitizedPath: parsed.sanitizedPath,
            watchedFolderID: watchedID,
            nowMs: clock()
        )
        eventSink(event)
    }
}
