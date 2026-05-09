import XCTest
@testable import LeafCore

final class LinearIDExtractorTests: XCTestCase {

    // MARK: - Pure-function `extract`

    func testExtract_SimpleMatch() {
        XCTAssertEqual(
            LinearIDExtractor.extract(text: "Fix LEAF-123", knownPrefixes: ["LEAF"]),
            "LEAF-123"
        )
    }

    func testExtract_NoMatch() {
        XCTAssertNil(
            LinearIDExtractor.extract(text: "no ids here", knownPrefixes: ["LEAF"])
        )
    }

    /// "MAX-1024" matches regex но prefix не whitelist'ed → nil.
    func testExtract_WrongPrefixRejected() {
        XCTAssertNil(
            LinearIDExtractor.extract(text: "screen 1920x1080 MAX-1024 pixels",
                                      knownPrefixes: ["LEAF", "ENG"])
        )
    }

    func testExtract_RFCFalsePositive() {
        XCTAssertNil(
            LinearIDExtractor.extract(text: "see RFC-2119 для key words",
                                      knownPrefixes: ["LEAF"])
        )
    }

    /// Multiple matches → first wins (commit subject convention).
    func testExtract_MultipleMatches_FirstWins() {
        XCTAssertEqual(
            LinearIDExtractor.extract(
                text: "depends on LEAF-1, fixes LEAF-2",
                knownPrefixes: ["LEAF"]
            ),
            "LEAF-1"
        )
    }

    /// Lowercase rejected (case-sensitive — снижаем false positives типа "non-1").
    func testExtract_LowercaseRejected() {
        XCTAssertNil(
            LinearIDExtractor.extract(text: "fix leaf-123", knownPrefixes: ["LEAF", "leaf"])
        )
    }

    /// Prefix > 5 chars не matches (regex max). Even если whitelisted.
    func testExtract_PrefixTooLong() {
        XCTAssertNil(
            LinearIDExtractor.extract(text: "ABCDEF-1", knownPrefixes: ["ABCDEF"])
        )
    }

    /// Prefix < 2 chars не matches (regex min — first char + 1-4 more = 2-5 total).
    func testExtract_PrefixTooShort() {
        XCTAssertNil(
            LinearIDExtractor.extract(text: "X-1", knownPrefixes: ["X"])
        )
    }

    /// "LEAF-abc" не matches — после dash должны быть digits.
    func testExtract_DigitsRequired() {
        XCTAssertNil(
            LinearIDExtractor.extract(text: "LEAF-abc", knownPrefixes: ["LEAF"])
        )
    }

    /// Linear allows team keys с digits (e.g. "TEAM2"). Regex
    /// `[A-Z][A-Z0-9]{1,4}-\d+` поддерживает.
    func testExtract_TeamKeyWithDigits() {
        XCTAssertEqual(
            LinearIDExtractor.extract(text: "ship TEAM2-99", knownPrefixes: ["TEAM2"]),
            "TEAM2-99"
        )
    }

    /// Empty whitelist → nil немедленно (graceful no-op).
    func testExtract_EmptyKnownPrefixes() {
        XCTAssertNil(
            LinearIDExtractor.extract(text: "LEAF-1", knownPrefixes: [])
        )
    }

    func testExtract_EmptyText() {
        XCTAssertNil(
            LinearIDExtractor.extract(text: "", knownPrefixes: ["LEAF"])
        )
    }

    /// Non-ASCII letters считаются word-boundary chars в NSRegularExpression
    /// → regex matches LEAF-1 surrounded русскими словами. Acceptable behaviour.
    func testExtract_UnicodeBoundary() {
        XCTAssertEqual(
            LinearIDExtractor.extract(text: "Привет LEAF-1 мир", knownPrefixes: ["LEAF"]),
            "LEAF-1"
        )
    }

    // MARK: - LinearIDPrefixCache

    func testCache_FirstAccessFetchesFromSource() async {
        let cache = LinearIDPrefixCache(fetcher: { ["LEAF", "ENG"] })
        let result = await cache.currentPrefixes()
        XCTAssertEqual(result, ["LEAF", "ENG"])
    }

    func testCache_SubsequentAccessWithinTTLReturnsCachedValue() async {
        let counter = CallCounter()
        let cache = LinearIDPrefixCache(
            fetcher: {
                await counter.increment()
                return ["LEAF"]
            },
            ttl: 60  // достаточно длинный TTL — сразу второй вызов попадает в cache
        )
        _ = await cache.currentPrefixes()
        _ = await cache.currentPrefixes()
        let count = await counter.get()
        XCTAssertEqual(count, 1, "fetcher вызывается только один раз в окне TTL")
    }

    func testCache_InvalidateForcesRefresh() async {
        let counter = CallCounter()
        let cache = LinearIDPrefixCache(
            fetcher: {
                await counter.increment()
                return ["LEAF"]
            },
            ttl: 3600
        )
        _ = await cache.currentPrefixes()
        await cache.invalidate()
        _ = await cache.currentPrefixes()
        let count = await counter.get()
        XCTAssertEqual(count, 2, "invalidate сбрасывает TTL — следующий доступ refresh'ит")
    }

    /// Helper actor для счётчика вызовов fetcher'а.
    private actor CallCounter {
        private var count = 0
        func increment() { count += 1 }
        func get() -> Int { count }
    }

    func testExtractAll_MultipleMatches_OrderedDedup() {
        let result = LinearIDExtractor.extractAll(
            text: "LEAF-127 and LEAF-200 and LEAF-127 again",
            knownPrefixes: ["LEAF"]
        )
        XCTAssertEqual(result, ["LEAF-127", "LEAF-200"])
    }

    func testExtractAll_EmptyKnownPrefixes_ReturnsEmpty() {
        let result = LinearIDExtractor.extractAll(text: "LEAF-127", knownPrefixes: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testExtractAll_NoMatches_ReturnsEmpty() {
        let result = LinearIDExtractor.extractAll(
            text: "no matches here at all",
            knownPrefixes: ["LEAF"]
        )
        XCTAssertTrue(result.isEmpty)
    }
}
