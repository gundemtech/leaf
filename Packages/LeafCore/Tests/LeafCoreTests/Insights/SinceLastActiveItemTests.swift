import XCTest

@testable import LeafCore

final class SinceLastActiveItemTests: XCTestCase {
    func test_equatable_byContent() {
        let a = SinceLastActiveItem(
            severity: .muted, verb: "merged", actorPrefix: "you",
            targetTitle: "PR #142", sourceMeta: "leaf",
            tsMs: 1_700_000_000_000, source: .github,
            sourceURL: URL(string: "https://github.com/gundemtech/leaf/pull/142")
        )
        let b = SinceLastActiveItem(
            severity: .muted, verb: "merged", actorPrefix: "you",
            targetTitle: "PR #142", sourceMeta: "leaf",
            tsMs: 1_700_000_000_000, source: .github,
            sourceURL: URL(string: "https://github.com/gundemtech/leaf/pull/142")
        )
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func test_uniqueKey_compositeStable() {
        let item = SinceLastActiveItem(
            severity: .warn, verb: "requested your review on", actorPrefix: "anton",
            targetTitle: "Refactor Sparkle gating", sourceMeta: "PR #143 · leaf",
            tsMs: 1_700_000_000_000, source: .github,
            sourceURL: nil
        )
        // Home redesign — targetTitle joined the composite (sourceMeta is
        // frequently empty after the meta-dedup; title keeps keys unique).
        XCTAssertEqual(
            item.uniqueKey,
            "github-requested your review on-1700000000000-Refactor Sparkle gating-PR #143 · leaf"
        )
    }

    func test_sendableAndHashable_inSet_dedupContent() {
        let a = SinceLastActiveItem(
            severity: .danger, verb: "blocker:", actorPrefix: "",
            targetTitle: "Sasha needs Linear OAuth scope",
            sourceMeta: "Track-1 D3", tsMs: 1, source: .detection, sourceURL: nil
        )
        let b = SinceLastActiveItem(
            severity: .danger, verb: "blocker:", actorPrefix: "",
            targetTitle: "Sasha needs Linear OAuth scope",
            sourceMeta: "Track-1 D3", tsMs: 1, source: .detection, sourceURL: nil
        )
        XCTAssertEqual(Set([a, b]).count, 1)
    }
}
