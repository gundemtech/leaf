import XCTest

@testable import LeafCore

/// Phase 3 — the comparator that decides whether an installed build is NEWER than
/// the last release the user saw. The trap it guards: comparing alpha versions as
/// plain strings ("alpha.9" > "alpha.28" lexically) would suppress every What's New
/// past alpha.9. So the prerelease numeric identifier MUST compare by integer.
final class SemverPrereleaseTests: XCTestCase {

    // MARK: parsing

    func test_parsesReleaseTriple() {
        let v = SemverPrerelease("1.2.3")
        XCTAssertEqual(v?.major, 1)
        XCTAssertEqual(v?.minor, 2)
        XCTAssertEqual(v?.patch, 3)
        XCTAssertEqual(v?.isPrerelease, false)
    }

    func test_parsesAlphaPrerelease() {
        let v = SemverPrerelease("1.0.0-alpha.30")
        XCTAssertEqual(v?.major, 1)
        XCTAssertEqual(v?.patch, 0)
        XCTAssertEqual(v?.isPrerelease, true)
    }

    func test_rejectsGarbage() {
        XCTAssertNil(SemverPrerelease("abc"))
        XCTAssertNil(SemverPrerelease("1.0"))          // not enough components
        XCTAssertNil(SemverPrerelease(""))
        XCTAssertNil(SemverPrerelease("1.0.x"))        // non-numeric patch
    }

    // MARK: the core regression — numeric prerelease ordering

    func test_alphaNumericOrdering_9_before_28() {
        XCTAssertLessThan(SemverPrerelease("1.0.0-alpha.9")!, SemverPrerelease("1.0.0-alpha.28")!)
    }

    func test_alpha30_greaterThan_alpha29() {
        XCTAssertGreaterThan(SemverPrerelease("1.0.0-alpha.30")!, SemverPrerelease("1.0.0-alpha.29")!)
    }

    func test_equalVersions() {
        XCTAssertEqual(SemverPrerelease("1.0.0-alpha.30")!, SemverPrerelease("1.0.0-alpha.30")!)
        XCTAssertFalse(SemverPrerelease("1.0.0-alpha.30")! < SemverPrerelease("1.0.0-alpha.30")!)
    }

    // MARK: semver precedence rules

    func test_releaseGreaterThanItsPrerelease() {
        // 1.0.0 (GA) outranks 1.0.0-alpha.30 — a shipped GA must show What's New
        // over the last-seen prerelease.
        XCTAssertGreaterThan(SemverPrerelease("1.0.0")!, SemverPrerelease("1.0.0-alpha.30")!)
    }

    func test_patchDominatesPrerelease() {
        XCTAssertGreaterThan(SemverPrerelease("1.0.1-alpha.1")!, SemverPrerelease("1.0.0-alpha.99")!)
    }

    func test_minorAndMajorOrdering() {
        XCTAssertGreaterThan(SemverPrerelease("1.1.0")!, SemverPrerelease("1.0.5")!)
        XCTAssertGreaterThan(SemverPrerelease("2.0.0")!, SemverPrerelease("1.9.9")!)
    }

    func test_fewerPrereleaseFieldsLowerPrecedence() {
        // semver §11.4.4: a larger set of identifiers > smaller, if all preceding equal.
        XCTAssertLessThan(SemverPrerelease("1.0.0-alpha")!, SemverPrerelease("1.0.0-alpha.1")!)
    }

    func test_numericIdentifierLowerThanAlphanumeric() {
        // semver §11.4.3: numeric identifiers always have lower precedence than
        // alphanumeric ones.
        XCTAssertLessThan(SemverPrerelease("1.0.0-1")!, SemverPrerelease("1.0.0-alpha")!)
    }

    func test_alphanumericLexicalOrdering() {
        XCTAssertLessThan(SemverPrerelease("1.0.0-alpha.1")!, SemverPrerelease("1.0.0-beta.1")!)
    }
}
