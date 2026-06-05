import XCTest

@testable import LeafCore

/// Track AI Coworker P3 — the public egress-hygiene transform that de-leaks a
/// GitHub PR `target_ref`: `owner/repo/pull/42` → `#42` (strips the org/repo
/// slug). Value-level: the org/repo identity must be ABSENT from the result.
final class PRRefNormalizerTests: XCTestCase {
  func testCanonicalNormalizes() {
    XCTAssertEqual(PRRefNormalizer.bareNumber(fromCanonicalPRRef: "owner/repo/pull/42"), "#42")
    XCTAssertEqual(PRRefNormalizer.bareNumber(fromCanonicalPRRef: "acme/widgets/pull/7"), "#7")
  }

  func testOwnerRepoStrippedValueSentinel() {
    let out = PRRefNormalizer.bareNumber(fromCanonicalPRRef: "acme-corp/secret-repo/pull/42")
    XCTAssertEqual(out, "#42")
    XCTAssertFalse((out ?? "").contains("acme-corp"), "org slug must be stripped")
    XCTAssertFalse((out ?? "").contains("secret-repo"), "repo slug must be stripped")
  }

  func testNonCanonicalReturnsNil() {
    // Fail-closed: anything not a 4-segment */*/pull/<digits> → nil (caller drops).
    for bad in [
      "LEAF-88", "owner/repo/issues/5", "owner/repo/pull/", "owner/repo/pull/x",
      "a/b/c/pull/9", "owner/repo/pull/42/extra", "", "pull/42",
    ] {
      XCTAssertNil(
        PRRefNormalizer.bareNumber(fromCanonicalPRRef: bad), "non-canonical \"\(bad)\" must be nil")
    }
  }
}
