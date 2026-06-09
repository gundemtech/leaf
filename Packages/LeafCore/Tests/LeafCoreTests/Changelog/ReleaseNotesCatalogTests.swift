import XCTest

@testable import LeafCore

/// Phase 3 — `ReleaseNote` mirrors a releases.json entry and `ReleaseNotesCatalog`
/// decodes the bundled file. Decoding must be tolerant (unknown future keys ignored,
/// absent `yanked` = false) and graceful (a missing/malformed file yields an empty
/// catalog, never a crash) — the bundle is generated and could lag or be absent.
final class ReleaseNotesCatalogTests: XCTestCase {

    // A releases.json-shaped fixture (same shape gen-release-notes.sh emits), with
    // an unknown future key on the first record to prove tolerance.
    private let fixture = Data("""
    {
      "schemaVersion": 1,
      "releases": [
        { "version": "1.0.0-alpha.30", "date": "2026-06-09",
          "added": [], "fixed": ["fixed a thing", "fixed another"], "changed": [],
          "dmgURL": "https://updates.gundem.tech/releases/Leaf-1.0.0-alpha.30.dmg",
          "zipURL": "https://updates.gundem.tech/releases/Leaf-1.0.0-alpha.30.zip",
          "futureField": "must be ignored" },
        { "version": "1.0.0-alpha.3", "date": "2026-03-03",
          "added": ["a feature"], "fixed": [], "changed": ["a tweak"],
          "dmgURL": "https://updates.gundem.tech/releases/Leaf-1.0.0-alpha.3.dmg",
          "zipURL": "https://updates.gundem.tech/releases/Leaf-1.0.0-alpha.3.zip",
          "yanked": true }
      ]
    }
    """.utf8)

    // MARK: ReleaseNote decoding

    func test_decodesAllFields() {
        let catalog = ReleaseNotesCatalog.decode(from: fixture)
        let first = catalog.releases.first
        XCTAssertEqual(first?.version, "1.0.0-alpha.30")
        XCTAssertEqual(first?.date, "2026-06-09")
        XCTAssertEqual(first?.fixed, ["fixed a thing", "fixed another"])
        XCTAssertEqual(first?.added, [])
        XCTAssertEqual(first?.changed, [])
    }

    func test_yankedDefaultsFalse_andParsesTrue() {
        let catalog = ReleaseNotesCatalog.decode(from: fixture)
        XCTAssertEqual(catalog.releases[0].yanked, false)   // absent → false
        XCTAssertEqual(catalog.releases[1].yanked, true)    // present → true
    }

    func test_unknownFutureKeyTolerated() {
        // The "futureField" on record 0 must not break decoding (forward-compat).
        let catalog = ReleaseNotesCatalog.decode(from: fixture)
        XCTAssertEqual(catalog.releases.count, 2)
    }

    // MARK: catalog ordering + latest

    func test_newestFirstPreservedAndLatest() {
        let catalog = ReleaseNotesCatalog.decode(from: fixture)
        XCTAssertEqual(catalog.releases.map(\.version), ["1.0.0-alpha.30", "1.0.0-alpha.3"])
        XCTAssertEqual(catalog.latest?.version, "1.0.0-alpha.30")
    }

    // MARK: graceful degradation

    func test_malformedJSON_yieldsEmptyCatalog() {
        let catalog = ReleaseNotesCatalog.decode(from: Data("{ not json".utf8))
        XCTAssertTrue(catalog.releases.isEmpty)
        XCTAssertNil(catalog.latest)
    }

    func test_emptyReleasesArray() {
        let catalog = ReleaseNotesCatalog.decode(from: Data(#"{"schemaVersion":1,"releases":[]}"#.utf8))
        XCTAssertTrue(catalog.releases.isEmpty)
    }

    func test_missingSchemaVersionTolerated() {
        let data = Data(#"{"releases":[{"version":"1.0.0","date":"2026-01-01","added":[],"fixed":[],"changed":[],"dmgURL":"u","zipURL":"u"}]}"#.utf8)
        let catalog = ReleaseNotesCatalog.decode(from: data)
        XCTAssertEqual(catalog.latest?.version, "1.0.0")
    }

    func test_bundledMissingResource_yieldsEmptyCatalog() {
        // An empty bundle has no releases.json → graceful empty, not a crash.
        let catalog = ReleaseNotesCatalog.bundled(in: Bundle(for: Self.self))
        // Bundle(for:) is the test bundle; it carries no releases.json, so empty.
        XCTAssertTrue(catalog.releases.isEmpty)
    }
}
