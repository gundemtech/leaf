import Foundation

/// Track-6 P6 — FSEvents watcher for VSCode-family `workspaceStorage/<hash>/`
/// directory creation events. On CREATE: loads `workspace.json`, URL-decodes
/// `folder` URI, home-dir-sanitizes (`/Users/alice/...` → `~/...`),
/// resolves against `WatchedFolderStore`, emits `vscode_workspace_opened`.
///
/// Privacy walkback at parser boundary:
///   1. URL-decode percent escapes.
///   2. Replace $HOME prefix with `~/`.
///   3. Resolve against watched-folder bookmarks.
///   4. Inside-watched → payload {workspace_name (basename), watched_folder_id,
///      outside_watched_folder=false, workspace_root (~/-prefixed, Track-9 T1)}.
///   5. Outside-watched → payload {workspace_name (basename only),
///      outside_watched_folder=true, workspace_root (~/-prefixed, Track-9 T1)}.
///   6. Track-9 T1: MAY emit tilde-prefixed sanitized workspace path (~/...)
///      for substrate consumers' git-HEAD walk in T5 YOU·NOW deriver.
///   7. NEVER bare absolute path with $HOME username (/Users/<name>/...) in payload.
///   8. workspace_root field is gated by LocalAppsStore.ideWorkspacePathTrackingEnabled
///      (default ON); when OFF, field is omitted (graceful degrade).
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
        "Code",  // VSCode stable
        "Cursor",  // Cursor (ToDesktop)
        "Code - Insiders",  // VSCode Insiders
        "VSCodium",
    ]

    public static func inferBundleID(forVendorRoot root: String) -> String? {
        switch root {
        case "Code": return VSCodeStableParser.bundleID
        case "Cursor": return CursorParser.bundleID
        case "Code - Insiders": return VSCodeInsidersParser.bundleID
        case "VSCodium": return VSCodiumParser.bundleID
        default: return nil
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

    /// Build the RawEvent. `sanitizedPath` is tilde-prefixed (~/...) and
    /// emitted as `workspace_root` when `workspaceRootEnabled` is true AND
    /// the path starts with `~`. NEVER emits bare absolute /Users/... path.
    public static func buildEvent(
        bundleID: String,
        workspaceName: String,
        sanitizedPath: String,
        watchedFolderID: String?,
        nowMs: Int64,
        workspaceRootEnabled: Bool = true
    ) -> RawEvent {
        var payload: [String: String] = [
            "event_kind": "vscode_workspace_opened",
            "ide_bundle_id": bundleID,
            "workspace_name": workspaceName,
        ]
        if let id = watchedFolderID {
            payload["watched_folder_id"] = id
            payload["outside_watched_folder"] = "false"
        } else {
            payload["outside_watched_folder"] = "true"
        }
        if workspaceRootEnabled {
            // Defense-in-depth: only emit if path is tilde-prefixed.
            // Bare absolute paths (/Users/<name>/...) must NEVER reach payload.
            if sanitizedPath.hasPrefix("~") {
                payload["workspace_root"] = sanitizedPath
            }
            // else (absolute /Users/... or empty): silently drop.
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
    private let watchedFolderResolver: @Sendable (_ path: String) -> String?
    private let eventSink: @Sendable (RawEvent) -> Void
    private let clock: @Sendable () -> Int64
    private let localAppsStore: LocalAppsStore
    /// One FSEvents stream per existing vendor root's `workspaceStorage/`.
    private var streams: [FSEventStream] = []

    public init(
        homeDir: String = NSHomeDirectory(),
        watchedFolderResolver: @escaping @Sendable (_ path: String) -> String?,
        eventSink: @escaping @Sendable (RawEvent) -> Void,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        localAppsStore: LocalAppsStore = LocalAppsStore()
    ) {
        self.homeDir = homeDir
        self.watchedFolderResolver = watchedFolderResolver
        self.eventSink = eventSink
        self.clock = clock
        self.localAppsStore = localAppsStore
    }

    public func start() async {
        // Feature gate (ADR-020 opt-in): no streams unless the user enabled
        // VSCode-family workspace tracking. Toggle-flip takes effect on Agent
        // restart (mirror P3 BrowserBookmarksWatcher v1 constraint).
        guard localAppsStore.vscodeStorageEnabled else { return }
        let base = homeDir + "/Library/Application Support/"
        for root in Self.vendorRoots {
            let storagePath = base + root + "/User/workspaceStorage"
            guard FileManager.default.fileExists(atPath: storagePath) else { continue }
            // One stream per existing vendor root; the closure captures `root`
            // so we never need to parse the vendor back out of the event path.
            // Cold path: kFSEventStreamEventIdSinceNow → no replay of existing
            // workspaceStorage/<hash>/ dirs (stale-timestamped).
            let onEvents: FSEventStream.EventsHandler = { [weak self] paths, _ in
                guard let self else { return }
                for path in paths where path.hasSuffix("/workspace.json") {
                    // Keep the @Sendable utility-queue callback cheap: hop into
                    // the actor and read the file there (avoid blocking the
                    // shared FSEvents queue on disk I/O).
                    Task { await self.handleWorkspaceFile(vendorRoot: root, path: path) }
                }
            }
            guard let stream = try? FSEventStream(
                paths: [storagePath],
                latency: 1.5,
                queueLabel: "tech.gundem.leaf.fsevents.vscode",
                onEvents: onEvents
            ) else { continue }
            stream.start()
            streams.append(stream)
        }
    }

    public func stop() async {
        for stream in streams { stream.stop() }
        streams.removeAll()
    }

    /// Read a `workspace.json` discovered by FSEvents and feed it through the
    /// shared parse+emit path. Runs inside actor isolation (called from the
    /// callback's `Task`-hop), so the disk read is off the FSEvents queue.
    private func handleWorkspaceFile(vendorRoot: String, path: String) async {
        // Defense-in-depth: drop events if the toggle flipped off after start().
        guard localAppsStore.vscodeStorageEnabled else { return }
        guard let body = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        await onWorkspaceStorageDirCreated(vendorRoot: vendorRoot, workspaceJSONBody: body)
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
        let workspaceRootEnabled = localAppsStore.ideWorkspacePathTrackingEnabled
        let event = Self.buildEvent(
            bundleID: bundleID,
            workspaceName: parsed.workspaceName,
            sanitizedPath: parsed.sanitizedPath,
            watchedFolderID: watchedID,
            nowMs: clock(),
            workspaceRootEnabled: workspaceRootEnabled
        )
        eventSink(event)
    }
}
