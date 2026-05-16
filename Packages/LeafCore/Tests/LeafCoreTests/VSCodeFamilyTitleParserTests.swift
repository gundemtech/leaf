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
}
