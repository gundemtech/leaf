import XCTest

@testable import LeafCore

/// Settings dead-toggle remediation (WS1) — unit tests for the net-new
/// path→watchedFolderID resolver shared by the IDE watchers. The watcher passes
/// a tilde-prefixed path (`~/...`); watched-folder rows store canonical absolute
/// paths, so the resolver expands `~` before prefix-matching.
final class WatchedFolderResolverTests: XCTestCase {

    private func folder(
        _ id: String, _ path: String, enabled: Bool = true
    ) -> WatchedFolder {
        WatchedFolder(
            id: id, path: path, maxGranularity: .L4, enabled: enabled,
            addedAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0))
    }

    func test_resolveID_prefixMatchReturnsID() {
        let folders = [folder("FID-1", "/Users/alice/Desktop/Leaf")]
        XCTAssertEqual(
            WatchedFolderResolver.resolveID(
                tildePath: "~/Desktop/Leaf/leaf", in: folders, homeDir: "/Users/alice"),
            "FID-1")
    }

    func test_resolveID_exactMatchReturnsID() {
        let folders = [folder("FID-2", "/Users/alice/Desktop/Leaf")]
        XCTAssertEqual(
            WatchedFolderResolver.resolveID(
                tildePath: "~/Desktop/Leaf", in: folders, homeDir: "/Users/alice"),
            "FID-2")
    }

    func test_resolveID_noMatchReturnsNil() {
        let folders = [folder("FID-3", "/Users/alice/Desktop/Leaf")]
        XCTAssertNil(
            WatchedFolderResolver.resolveID(
                tildePath: "~/Documents/Other", in: folders, homeDir: "/Users/alice"))
    }

    func test_resolveID_siblingPrefixIsNotFalsePositive() {
        // "/Users/alice/Desktop/Leaf" must NOT match "~/Desktop/LeafOther".
        let folders = [folder("FID-4", "/Users/alice/Desktop/Leaf")]
        XCTAssertNil(
            WatchedFolderResolver.resolveID(
                tildePath: "~/Desktop/LeafOther", in: folders, homeDir: "/Users/alice"))
    }

    func test_resolveID_skipsDisabledFolder() {
        let folders = [folder("FID-5", "/Users/alice/Desktop/Leaf", enabled: false)]
        XCTAssertNil(
            WatchedFolderResolver.resolveID(
                tildePath: "~/Desktop/Leaf/leaf", in: folders, homeDir: "/Users/alice"))
    }

    func test_resolveID_trailingSlashOnFolderPathTolerated() {
        let folders = [folder("FID-6", "/Users/alice/Desktop/Leaf/")]
        XCTAssertEqual(
            WatchedFolderResolver.resolveID(
                tildePath: "~/Desktop/Leaf/leaf", in: folders, homeDir: "/Users/alice"),
            "FID-6")
    }

    func test_resolveID_nonPathInputReturnsNil() {
        let folders = [folder("FID-7", "/Users/alice/Desktop/Leaf")]
        XCTAssertNil(
            WatchedFolderResolver.resolveID(
                tildePath: "relative/no/prefix", in: folders, homeDir: "/Users/alice"))
    }
}
