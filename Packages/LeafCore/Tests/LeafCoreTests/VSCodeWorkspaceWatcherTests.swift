import XCTest
@testable import LeafCore

final class VSCodeWorkspaceWatcherTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "P6-vscode-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_parseWorkspaceJSON_urlDecodesAndSanitizes() {
        let json = #"""
        {"folder":"file:///Users/alice/Desktop/Project%20Name"}
        """#
        let parsed = VSCodeWorkspaceWatcher.parseWorkspaceJSON(json, homeDir: "/Users/alice")
        XCTAssertEqual(parsed?.workspaceName, "Project Name")
        XCTAssertEqual(parsed?.sanitizedPath, "~/Desktop/Project Name")
    }

    func test_parseWorkspaceJSON_homeDirReplacedWithTilde() {
        let json = #"{"folder":"file:///Users/alice/Documents/code/leaf"}"#
        let parsed = VSCodeWorkspaceWatcher.parseWorkspaceJSON(json, homeDir: "/Users/alice")
        XCTAssertEqual(parsed?.workspaceName, "leaf")
        XCTAssertTrue(parsed?.sanitizedPath.hasPrefix("~/") ?? false)
    }

    func test_parseWorkspaceJSON_malformedReturnsNil() {
        XCTAssertNil(VSCodeWorkspaceWatcher.parseWorkspaceJSON("not json", homeDir: "/Users/alice"))
        XCTAssertNil(VSCodeWorkspaceWatcher.parseWorkspaceJSON("{}", homeDir: "/Users/alice"))
        XCTAssertNil(VSCodeWorkspaceWatcher.parseWorkspaceJSON(#"{"folder":""}"#, homeDir: "/Users/alice"))
    }

    func test_buildEvent_outsideWatchedFolder_basenameOnly_noPath() {
        let event = VSCodeWorkspaceWatcher.buildEvent(
            bundleID: "com.microsoft.VSCode",
            workspaceName: "SecretWorkspace",
            sanitizedPath: "~/Desktop/SecretWorkspace",
            watchedFolderID: nil,
            nowMs: 1_000
        )
        XCTAssertEqual(event.payload["event_kind"], "vscode_workspace_opened")
        XCTAssertEqual(event.payload["workspace_name"], "SecretWorkspace")
        XCTAssertEqual(event.payload["outside_watched_folder"], "true")
        XCTAssertNil(event.payload["watched_folder_id"])
        // Sanitized path must NOT leak into payload when outside watched folder.
        for (_, v) in event.payload {
            XCTAssertFalse(v.contains("Desktop"),
                "leaked path component when outside_watched_folder=true: \(v)")
        }
    }

    func test_buildEvent_insideWatchedFolder_includesUUID() {
        let event = VSCodeWorkspaceWatcher.buildEvent(
            bundleID: "com.microsoft.VSCode",
            workspaceName: "leaf",
            sanitizedPath: "~/Desktop/Leaf/leaf",
            watchedFolderID: "F47AC10B-58CC-4372-A567-0E02B2C3D479",
            nowMs: 1_000
        )
        XCTAssertEqual(event.payload["watched_folder_id"], "F47AC10B-58CC-4372-A567-0E02B2C3D479")
        XCTAssertEqual(event.payload["outside_watched_folder"], "false")
        // Even with watched-folder match, full path must NOT appear in payload.
        for (_, v) in event.payload {
            XCTAssertFalse(v.contains("/Users/"),
                "absolute path leaked into payload: \(v)")
        }
    }

    func test_inferBundleID_fromVendorRoot() {
        XCTAssertEqual(
            VSCodeWorkspaceWatcher.inferBundleID(forVendorRoot: "Code"),
            "com.microsoft.VSCode")
        XCTAssertEqual(
            VSCodeWorkspaceWatcher.inferBundleID(forVendorRoot: "Cursor"),
            "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(
            VSCodeWorkspaceWatcher.inferBundleID(forVendorRoot: "Code - Insiders"),
            "com.microsoft.VSCodeInsiders")
        XCTAssertEqual(
            VSCodeWorkspaceWatcher.inferBundleID(forVendorRoot: "VSCodium"),
            "com.visualstudio.code.oss")
        XCTAssertNil(VSCodeWorkspaceWatcher.inferBundleID(forVendorRoot: "UnknownEditor"))
    }
}
