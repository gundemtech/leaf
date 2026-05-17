import XCTest
@testable import LeafCore

final class URLDomainExtractorTests: XCTestCase {

    func testStandardHTTPS() {
        XCTAssertEqual(URLDomainExtractor.domain(of: "https://example.com/foo/bar"), "example.com")
    }

    func testSchemeCaseDoesNotMatter() {
        XCTAssertEqual(URLDomainExtractor.domain(of: "HTTPS://example.com/"), "example.com")
    }

    func testHostCaseIsLowercased() {
        XCTAssertEqual(URLDomainExtractor.domain(of: "https://EXAMPLE.com/foo"), "example.com")
    }

    func testPortIsStripped() {
        XCTAssertEqual(URLDomainExtractor.domain(of: "https://EXAMPLE.com:8080/foo"), "example.com")
    }

    func testFileURLReturnsNil() {
        XCTAssertNil(URLDomainExtractor.domain(of: "file:///etc/hosts"))
    }

    func testIPv4ReturnedVerbatim() {
        XCTAssertEqual(URLDomainExtractor.domain(of: "http://192.168.1.1/"), "192.168.1.1")
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(URLDomainExtractor.domain(of: ""))
    }

    func testMalformedNoSchemeReturnsNil() {
        XCTAssertNil(URLDomainExtractor.domain(of: "not a url at all"))
    }

    func testWhitespaceOnlyReturnsNil() {
        XCTAssertNil(URLDomainExtractor.domain(of: "   "))
    }
}
