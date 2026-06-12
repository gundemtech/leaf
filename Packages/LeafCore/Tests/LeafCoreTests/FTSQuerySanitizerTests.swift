// Use-case rebuild Track B1 — FTS5 user-query sanitization.
//
// Raw user text fed to MATCH is an injection surface for FTS5 *syntax*:
// `point-fetch` parses as a column filter ("no such column"), quotes/parens
// break the parser, `NOT`/`OR` flip semantics. Every token is therefore
// emitted as a quoted string (implicit AND), which also preserves
// hyphenated tokens like GUN-12 that the tokenizer keeps whole.

import XCTest
@testable import LeafCore

final class FTSQuerySanitizerTests: XCTestCase {

  func testPlainWords_QuotedAndJoined() {
    XCTAssertEqual(FTSQuerySanitizer.sanitize("queue here"), "\"queue\" \"here\"")
  }

  func testHyphenatedToken_Preserved() {
    XCTAssertEqual(FTSQuerySanitizer.sanitize("point-fetch"), "\"point-fetch\"")
    XCTAssertEqual(FTSQuerySanitizer.sanitize("GUN-12"), "\"GUN-12\"")
  }

  func testEmbeddedQuotes_EscapedNotBroken() {
    XCTAssertEqual(FTSQuerySanitizer.sanitize(#"say "hello""#), #""say" """hello""""#)
  }

  func testOperatorsAndPunctuation_Neutralized() {
    XCTAssertEqual(FTSQuerySanitizer.sanitize("why? (db OR cache)"),
                   "\"why?\" \"(db\" \"OR\" \"cache)\"")
  }

  func testEmptyAndWhitespace_ReturnsEmpty() {
    XCTAssertEqual(FTSQuerySanitizer.sanitize("   "), "")
    XCTAssertEqual(FTSQuerySanitizer.sanitize(""), "")
  }
}
