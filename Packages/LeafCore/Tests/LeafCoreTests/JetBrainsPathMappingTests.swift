import XCTest

@testable import LeafCore

/// Settings dead-toggle remediation (WS1) — pure path-mapping helpers for the
/// JetBrains FSEvents loop. No global state (`_versionDirResolver`) is touched,
/// so these are safe in any execution order.
final class JetBrainsPathMappingTests: XCTestCase {

    func test_versionDir_extractsProductVersionComponent() {
        XCTAssertEqual(
            JetBrainsRecentProjectsWatcher.versionDir(
                forPath:
                    "/Users/alice/Library/Application Support/JetBrains/IntelliJIdea2025.1/options/recentProjects.xml"
            ),
            "IntelliJIdea2025.1")
    }

    func test_versionDir_recentProjectDirectoriesVariant() {
        XCTAssertEqual(
            JetBrainsRecentProjectsWatcher.versionDir(
                forPath:
                    "/Users/alice/Library/Application Support/JetBrains/PyCharm2025.1/options/recentProjectDirectories.xml"
            ),
            "PyCharm2025.1")
    }

    func test_versionDir_nonOptionsPathReturnsNil() {
        // A path under JetBrains/<ver>/ but not in options/ is not a recents file.
        XCTAssertNil(
            JetBrainsRecentProjectsWatcher.versionDir(
                forPath:
                    "/Users/alice/Library/Application Support/JetBrains/GoLand2025.1/config/other.xml"
            ))
    }

    func test_versionDir_pathWithoutJetBrainsReturnsNil() {
        XCTAssertNil(
            JetBrainsRecentProjectsWatcher.versionDir(
                forPath: "/Users/alice/Library/Application Support/Code/User/workspaceStorage/x.json"))
    }

    func test_isRecentProjectsXML_matchesBothVariants() {
        XCTAssertTrue(
            JetBrainsRecentProjectsWatcher.isRecentProjectsXML("/x/options/recentProjects.xml"))
        XCTAssertTrue(
            JetBrainsRecentProjectsWatcher.isRecentProjectsXML(
                "/x/options/recentProjectDirectories.xml"))
    }

    func test_isRecentProjectsXML_rejectsOtherFiles() {
        XCTAssertFalse(
            JetBrainsRecentProjectsWatcher.isRecentProjectsXML("/x/options/other.xml"))
        XCTAssertFalse(JetBrainsRecentProjectsWatcher.isRecentProjectsXML("/x/recentProjects.json"))
    }
}
