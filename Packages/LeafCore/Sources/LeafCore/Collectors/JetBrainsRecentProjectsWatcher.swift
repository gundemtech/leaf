import Foundation

/// Track-6 P6 — FSEvents watcher for JetBrains
/// `~/Library/Application Support/JetBrains/<Product><Y>/options/recentProjects[Directories].xml`.
///
/// Discovery cadence (brainstorm Section E): FSEvents on parent
/// `~/Library/Application Support/JetBrains/` + one-time initial glob at
/// Agent start. New `<Product><Y>/` dir CREATE → 500ms debounce → glob for
/// `options/recentProjects*.xml` → register sub-stream. On xml UPDATE
/// (atomic write on project close + project switch), parse XML, diff
/// against last in-memory snapshot per file, emit
/// jetbrains_recent_project_observed for new entries.
///
/// Privacy walkback: XML body content beyond `displayName` +
/// `activationTimestamp` NEVER read. <runManager>, <frame>, scheme list,
/// debugger state — explicitly dropped by XMLParser delegate (only the
/// two whitelisted fields populate ParsedEntry).
public actor JetBrainsRecentProjectsWatcher {
    public struct ParsedEntry: Equatable, Sendable {
        public let displayName: String
        public let activationTimestampMs: Int64
        /// Tilde-prefixed workspace root extracted from the XML `<entry key="...">` attribute.
        /// Non-nil only when key starts with `$USER_HOME$`; other key prefixes yield nil.
        public let workspaceRoot: String?
    }

    public struct InferredIDE: Equatable {
        public let bundleID: String
        public let versionDir: String
    }

    /// Extract bundle ID from JetBrains version-dir component.
    /// `LeafCorePrivate` resolves the product → bundle mapping (moat).
    public static func inferIDE(fromVersionDir versionDir: String) -> InferredIDE? {
        // Public wrapper expects LeafCorePrivate-imported ProdJetBrainsProductMap.
        // For unit-testability, this method consults a static closure that
        // production sets at Agent boot to call into Prod map.
        _versionDirResolver?(versionDir)
    }

    /// Injection point for the prod-side product map. LeafAgent sets this
    /// at boot with `ProdJetBrainsProductMap.split` + `productToBundleID`.
    /// `nonisolated(unsafe)` — write-once at Agent boot before any concurrent
    /// access; tests reset in tearDown under serial XCTest execution.
    nonisolated(unsafe) public static var _versionDirResolver: ((String) -> InferredIDE?)?

    /// Parse recentProjects.xml or recentProjectDirectories.xml body.
    /// Returns entries with (displayName, activationTimestampMs). Malformed
    /// XML → empty array (caller logs, no emit).
    public static func parseRecentProjectsXML(_ xml: String) -> [ParsedEntry] {
        guard !xml.isEmpty, let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.entries
    }

    /// Convert a recentProjects.xml `<entry key="...">` value to a tilde-prefixed workspace root.
    /// Only `$USER_HOME$`-anchored keys produce a non-nil result; `$PROJECT_DIR$/...` and other
    /// prefixes return nil (not home-anchored, privacy-safe to omit).
    public static func extractWorkspaceRoot(fromKey key: String) -> String? {
        let prefix = "$USER_HOME$"
        guard key.hasPrefix(prefix) else { return nil }
        let suffix = String(key.dropFirst(prefix.count))
        return suffix.isEmpty ? "~" : "~" + suffix
    }

    /// Build the RawEvent.
    public static func buildEvent(
        bundleID: String,
        versionDir: String,
        displayName: String,
        activationTimestampMs: Int64,
        outsideWatchedFolder: Bool,
        workspaceRoot: String? = nil,
        workspaceRootEnabled: Bool = true
    ) -> RawEvent {
        var payload: [String: String] = [
            "event_kind": "jetbrains_recent_project_observed",
            "ide_bundle_id": bundleID,
            "ide_version_dir": versionDir,
            "project_name": displayName,
            "activation_timestamp_ms": String(activationTimestampMs),
            "outside_watched_folder": outsideWatchedFolder ? "true" : "false",
        ]
        // Include workspace_root only when tracking is enabled, root is present,
        // and it is tilde-prefixed (defense-in-depth: bare absolute paths are dropped).
        if workspaceRootEnabled, let root = workspaceRoot, root.hasPrefix("~") {
            payload["workspace_root"] = root
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: Double(activationTimestampMs) / 1000.0),
            signalType: .attention,
            bundleID: bundleID,
            payload: payload
        )
    }

    // MARK: - XML delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [ParsedEntry] = []
        private var currentDisplayName: String?
        private var currentActivationTs: Int64?
        private var currentWorkspaceRoot: String?
        private var inMetaInfo = false
        // Track nesting depth so we ignore children of <runManager>, <frame>,
        // etc — only top-level <option name="displayName" value="..."/> +
        // RecentProjectMetaInfo's activationTimestamp attribute reach state.
        private var depth = 0
        private var metaInfoDepth = 0

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            depth += 1
            if elementName == "entry", let key = attributeDict["key"] {
                // Capture tilde-prefix workspace root from the <entry key="..."> attribute.
                // Only $USER_HOME$-anchored keys are promoted; others yield nil.
                currentWorkspaceRoot = extractWorkspaceRoot(fromKey: key)
            } else if elementName == "RecentProjectMetaInfo" {
                inMetaInfo = true
                metaInfoDepth = depth
                currentDisplayName = nil
                currentActivationTs = nil
                if let ts = attributeDict["activationTimestamp"], let n = Int64(ts) {
                    currentActivationTs = n
                }
            } else if inMetaInfo, elementName == "option", depth == metaInfoDepth + 1 {
                // Only direct <option> children of RecentProjectMetaInfo —
                // ignores nested option inside runManager / frame / etc.
                if attributeDict["name"] == "displayName",
                    let v = attributeDict["value"]
                {
                    currentDisplayName = v
                } else if attributeDict["name"] == "activationTimestamp",
                    let v = attributeDict["value"], let n = Int64(v)
                {
                    // Some JetBrains XML variants put activationTimestamp as a
                    // child <option> rather than an attribute on RecentProjectMetaInfo.
                    currentActivationTs = n
                }
            }
            // Other children (runManager, frame, etc.) deliberately ignored.
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?
        ) {
            if elementName == "RecentProjectMetaInfo", inMetaInfo {
                if let name = currentDisplayName, let ts = currentActivationTs {
                    entries.append(
                        ParsedEntry(
                            displayName: name,
                            activationTimestampMs: ts,
                            workspaceRoot: currentWorkspaceRoot
                        ))
                }
                inMetaInfo = false
                currentDisplayName = nil
                currentActivationTs = nil
                // currentWorkspaceRoot is cleared when the next <entry> is encountered.
            }
            if elementName == "entry" {
                currentWorkspaceRoot = nil
            }
            depth -= 1
        }

        private func extractWorkspaceRoot(fromKey key: String) -> String? {
            JetBrainsRecentProjectsWatcher.extractWorkspaceRoot(fromKey: key)
        }
    }

    // MARK: - Lifecycle (stubbed — integration smoke in Stage 7)

    private let homeDir: String
    private let watchedFolderResolver: (_ path: String) -> String?
    private let eventSink: (RawEvent) -> Void
    private let clock: () -> Int64
    private let localAppsStore: LocalAppsStore

    public init(
        homeDir: String = NSHomeDirectory(),
        watchedFolderResolver: @escaping (_ path: String) -> String?,
        eventSink: @escaping (RawEvent) -> Void,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        localAppsStore: LocalAppsStore = LocalAppsStore()
    ) {
        self.homeDir = homeDir
        self.watchedFolderResolver = watchedFolderResolver
        self.eventSink = eventSink
        self.clock = clock
        self.localAppsStore = localAppsStore
    }

    public func start() async {
        // 1. Initial glob ~/Library/Application Support/JetBrains/<Product><Y>/options/recentProjects*.xml.
        // 2. Register FSEvents stream on parent dir (~/Library/Application Support/JetBrains/).
        // 3. For each matched IDE-version dir, register sub-stream on options/.
        // 4. On parent CREATE → 500ms debounce → re-glob → add streams.
        // 5. On xml UPDATE → parse → diff snapshot → emit per new entry.
        // Implementation deferred to Stage 7 integration smoke.
    }

    public func stop() async {
        // Tear down all streams.
    }

    /// Test hook — synthesize an XML-update event without real FSEvents.
    public func onRecentProjectsXMLUpdated(
        versionDir: String,
        xmlBody: String,
        priorSnapshot: [ParsedEntry] = []
    ) async -> [ParsedEntry] {
        guard let ide = Self.inferIDE(fromVersionDir: versionDir) else { return [] }
        let parsed = Self.parseRecentProjectsXML(xmlBody)
        // Emit only entries with newer activationTimestampMs than prior snapshot
        // (= new opens / activations since last tick).
        let priorMaxTs = priorSnapshot.map(\.activationTimestampMs).max() ?? 0
        let fresh = parsed.filter { $0.activationTimestampMs > priorMaxTs }
        // Gate workspace_root on the same flag used by VSCodeWorkspaceWatcher (Track-9 T1).
        let workspaceRootEnabled = localAppsStore.ideWorkspacePathTrackingEnabled
        for entry in fresh {
            let event = Self.buildEvent(
                bundleID: ide.bundleID,
                versionDir: ide.versionDir,
                displayName: entry.displayName,
                activationTimestampMs: entry.activationTimestampMs,
                outsideWatchedFolder: true,  // best-effort; watched-folder resolve in production wiring
                workspaceRoot: entry.workspaceRoot,
                workspaceRootEnabled: workspaceRootEnabled
            )
            eventSink(event)
        }
        return parsed
    }
}
