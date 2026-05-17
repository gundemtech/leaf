import XCTest

@testable import LeafCore

final class VSCodeFamilyTitleParserTests: XCTestCase {

    // MARK: - VSCode Stable

    func test_vscodeStable_defaultFormat() {
        let obs = VSCodeStableParser.parse("Foo.swift — leaf — Visual Studio Code")
        XCTAssertEqual(obs?.ideBundleID, "com.microsoft.VSCode")
        XCTAssertEqual(obs?.workspaceName, "leaf")
        XCTAssertEqual(obs?.fileBasename, "Foo.swift")
    }

    func test_vscodeStable_dirtyMarker() {
        let obs = VSCodeStableParser.parse("● Foo.swift — leaf — Visual Studio Code")
        XCTAssertEqual(obs?.workspaceName, "leaf")
        XCTAssertEqual(obs?.fileBasename, "Foo.swift")
    }

    func test_vscodeStable_singleFileMode() {
        let obs = VSCodeStableParser.parse("Foo.swift — Visual Studio Code")
        XCTAssertNil(obs?.workspaceName)
        XCTAssertEqual(obs?.fileBasename, "Foo.swift")
    }

    func test_vscodeStable_untitled() {
        let obs = VSCodeStableParser.parse("Untitled-1 — leaf — Visual Studio Code")
        XCTAssertEqual(obs?.fileBasename, "Untitled-1")
    }

    func test_vscodeStable_unicodeWorkspace() {
        let obs = VSCodeStableParser.parse("Foo.swift — Café — Visual Studio Code")
        XCTAssertEqual(obs?.workspaceName, "Café")
    }

    func test_vscodeStable_customizedTitleReturnsNil() {
        // User customized window.title — unknown shape. Parser returns nil,
        // planner emits ide_window_title_observed fallback.
        let obs = VSCodeStableParser.parse("[main] Foo.swift in leaf @ Visual Studio Code")
        XCTAssertNil(obs)
    }

    func test_vscodeStable_emptyTitleReturnsNil() {
        XCTAssertNil(VSCodeStableParser.parse(""))
        XCTAssertNil(VSCodeStableParser.parse("   "))
    }

    func test_vscodeStable_wrongAppNameReturnsNil() {
        // Cursor title fed to VSCode parser must return nil so that
        // VSCodeFamilyDispatcher can fall through to the right parser.
        let obs = VSCodeStableParser.parse("Foo.swift — leaf — Cursor")
        XCTAssertNil(obs)
    }

    func test_vscodeStable_sshPrefix() {
        let obs = VSCodeStableParser.parse("Foo.swift — [SSH: remote-box] leaf — Visual Studio Code")
        XCTAssertEqual(obs?.workspaceName, "leaf")  // SSH prefix stripped
    }

    // MARK: - Cursor

    func test_cursor_defaultFormat() {
        let obs = CursorParser.parse("Bar.swift — leaf — Cursor")
        XCTAssertEqual(obs?.ideBundleID, "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(obs?.workspaceName, "leaf")
        XCTAssertEqual(obs?.fileBasename, "Bar.swift")
    }

    func test_cursor_dirtyMarker() {
        let obs = CursorParser.parse("● Bar.swift — leaf — Cursor")
        XCTAssertEqual(obs?.fileBasename, "Bar.swift")
    }

    func test_cursor_singleFileMode() {
        let obs = CursorParser.parse("Bar.swift — Cursor")
        XCTAssertNil(obs?.workspaceName)
        XCTAssertEqual(obs?.fileBasename, "Bar.swift")
    }

    func test_cursor_wrongAppNameReturnsNil() {
        let obs = CursorParser.parse("Foo.swift — leaf — Visual Studio Code")
        XCTAssertNil(obs)
    }

    // MARK: - VSCode Insiders

    func test_insiders_defaultFormat() {
        let obs = VSCodeInsidersParser.parse("Foo.swift — leaf — Visual Studio Code - Insiders")
        XCTAssertEqual(obs?.ideBundleID, "com.microsoft.VSCodeInsiders")
        XCTAssertEqual(obs?.workspaceName, "leaf")
        XCTAssertEqual(obs?.fileBasename, "Foo.swift")
    }

    func test_insiders_singleFileMode() {
        let obs = VSCodeInsidersParser.parse("Foo.swift — Visual Studio Code - Insiders")
        XCTAssertNil(obs?.workspaceName)
        XCTAssertEqual(obs?.fileBasename, "Foo.swift")
    }

    func test_insiders_wrongAppNameReturnsNil() {
        let obs = VSCodeInsidersParser.parse("Foo.swift — leaf — Visual Studio Code")
        XCTAssertNil(obs)
    }

    // MARK: - VSCodium

    func test_vscodium_defaultFormat() {
        let obs = VSCodiumParser.parse("Baz.swift — leaf — VSCodium")
        XCTAssertEqual(obs?.ideBundleID, "com.visualstudio.code.oss")
        XCTAssertEqual(obs?.workspaceName, "leaf")
        XCTAssertEqual(obs?.fileBasename, "Baz.swift")
    }

    func test_vscodium_codiumAppName() {
        // Some VSCodium builds render appName as "Codium" not "VSCodium".
        let obs = VSCodiumParser.parse("Baz.swift — leaf — Codium")
        XCTAssertEqual(obs?.fileBasename, "Baz.swift")
        XCTAssertEqual(obs?.workspaceName, "leaf")
    }

    // MARK: - Dispatcher

    func test_dispatcher_routesByBundleID() {
        XCTAssertNotNil(
            VSCodeFamilyDispatcher.parse(
                bundleID: "com.microsoft.VSCode",
                title: "Foo.swift — leaf — Visual Studio Code"
            ))
        XCTAssertNotNil(
            VSCodeFamilyDispatcher.parse(
                bundleID: "com.todesktop.230313mzl4w4u92",
                title: "Foo.swift — leaf — Cursor"
            ))
        XCTAssertNotNil(
            VSCodeFamilyDispatcher.parse(
                bundleID: "com.microsoft.VSCodeInsiders",
                title: "Foo.swift — leaf — Visual Studio Code - Insiders"
            ))
        XCTAssertNotNil(
            VSCodeFamilyDispatcher.parse(
                bundleID: "com.visualstudio.code.oss",
                title: "Foo.swift — leaf — VSCodium"
            ))
    }

    func test_dispatcher_unknownBundleIDReturnsNil() {
        XCTAssertNil(
            VSCodeFamilyDispatcher.parse(
                bundleID: "com.example.UnknownEditor",
                title: "Foo.swift — leaf — Whatever"
            ))
    }

    func test_dispatcher_isVSCodeFamilyMembership() {
        XCTAssertTrue(VSCodeFamilyDispatcher.isVSCodeFamily(bundleID: "com.microsoft.VSCode"))
        XCTAssertTrue(VSCodeFamilyDispatcher.isVSCodeFamily(bundleID: "com.todesktop.230313mzl4w4u92"))
        XCTAssertTrue(VSCodeFamilyDispatcher.isVSCodeFamily(bundleID: "com.microsoft.VSCodeInsiders"))
        XCTAssertTrue(VSCodeFamilyDispatcher.isVSCodeFamily(bundleID: "com.visualstudio.code.oss"))
        XCTAssertFalse(VSCodeFamilyDispatcher.isVSCodeFamily(bundleID: "com.apple.dt.Xcode"))
    }
}
