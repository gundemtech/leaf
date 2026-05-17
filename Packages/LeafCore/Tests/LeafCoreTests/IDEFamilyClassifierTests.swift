import XCTest
@testable import LeafCore

final class IDEFamilyClassifierTests: XCTestCase {

    // MARK: - VSCode family (4 bundles, sourced from VSCodeFamilyDispatcher)

    func testVSCodeStable() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.microsoft.VSCode"), .vscodeFamily)
    }

    func testVSCodeInsiders() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.microsoft.VSCodeInsiders"), .vscodeFamily)
    }

    func testCursor() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.todesktop.230313mzl4w4u92"), .vscodeFamily)
    }

    func testVSCodium() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.visualstudio.code.oss"), .vscodeFamily)
    }

    // MARK: - JetBrains family (13 bundles)

    func testIntelliJUltimate() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.jetbrains.intellij"), .jetbrains)
    }

    func testIntelliJCommunity() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.jetbrains.intellij.ce"), .jetbrains)
    }

    func testPyCharmPro() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.jetbrains.pycharm"), .jetbrains)
    }

    func testPyCharmCommunity() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.jetbrains.pycharm.ce"), .jetbrains)
    }

    func testWebStorm() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.jetbrains.WebStorm"), .jetbrains)
    }

    func testPhpStorm() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.jetbrains.PhpStorm"), .jetbrains)
    }

    func testGoLand() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.jetbrains.goland"), .jetbrains)
    }

    func testCLion() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.jetbrains.CLion"), .jetbrains)
    }

    func testRubyMine() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.jetbrains.rubymine"), .jetbrains)
    }

    func testAndroidStudio() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.google.android.studio"), .jetbrains)
    }

    func testDataGrip() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.jetbrains.datagrip"), .jetbrains)
    }

    func testRustRover() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.jetbrains.rustrover"), .jetbrains)
    }

    func testDataSpell() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.jetbrains.dataspell"), .jetbrains)
    }

    // MARK: - Fallback

    func testXcodeFallsBack() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "com.apple.dt.Xcode"), .fallback)
    }

    func testEmptyStringFallsBack() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: ""), .fallback)
    }

    func testGarbageFallsBack() {
        XCTAssertEqual(IDEFamilyClassifier.family(forBundleID: "qwerty-not-a-bundle-id-12345"), .fallback)
    }

    // MARK: - RawValue round-trip

    func testRawValueRoundTrip() {
        XCTAssertEqual(IDEFamily.vscodeFamily.rawValue, "vscodeFamily")
        XCTAssertEqual(IDEFamily.jetbrains.rawValue, "jetbrains")
        XCTAssertEqual(IDEFamily.fallback.rawValue, "fallback")
    }
}
