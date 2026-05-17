// Packages/LeafCore/Tests/LeafCoreTests/BrowserAllowListFilterTests.swift
import XCTest

@testable import LeafCore

final class BrowserAllowListFilterTests: XCTestCase {
    func testExtractDomainSimple() {
        XCTAssertEqual(extractDomain("https://github.com/foo/bar"), "github.com")
    }

    func testExtractDomainLowercased() {
        XCTAssertEqual(extractDomain("https://GITHUB.com/X"), "github.com")
    }

    func testExtractDomainEmptyOnNonStandardScheme() {
        XCTAssertEqual(extractDomain("about:blank"), "")
        XCTAssertEqual(extractDomain("chrome://settings"), "")
    }

    func testApplyGranularityFullUrlPassthrough() {
        XCTAssertEqual(
            applyGranularity("https://github.com/foo?q=1", .fullUrl),
            "https://github.com/foo?q=1")
    }

    func testApplyGranularityPathStrippedDropsQuery() {
        XCTAssertEqual(
            applyGranularity("https://github.com/foo?q=1", .pathStripped),
            "github.com/foo")
    }

    func testApplyGranularityDomainOnly() {
        XCTAssertEqual(
            applyGranularity("https://github.com/foo/bar?q=1", .domainOnly),
            "github.com")
    }

    func testInMemoryReaderDefaultDomainOnly() {
        let reader = InMemoryDomainAllowListReader(rules: [:])
        XCTAssertEqual(reader.granularity(for: "github.com"), .domainOnly)
    }

    func testInMemoryReaderReturnsRegisteredGranularity() {
        let reader = InMemoryDomainAllowListReader(rules: ["github.com": .fullUrl])
        XCTAssertEqual(reader.granularity(for: "github.com"), .fullUrl)
        XCTAssertEqual(
            reader.granularity(for: "api.github.com"), .domainOnly,
            "subdomain match is exact-only")
    }
}
