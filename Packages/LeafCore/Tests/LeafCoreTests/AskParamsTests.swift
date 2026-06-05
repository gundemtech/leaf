import XCTest

@testable import LeafCore

final class AskParamsTests: XCTestCase {
  func testRequiresQuestion() {
    for args: Any? in [["period": "today"] as [String: Any], ["question": "   "], nil] {
      guard case .error = AskParams.decode(arguments: args) else {
        return XCTFail("missing/blank question must error: \(String(describing: args))")
      }
    }
  }

  func testDefaultsPeriodToToday() {
    guard case .ok(let r) = AskParams.decode(arguments: ["question": "what did I do"]) else {
      return XCTFail("valid question should decode")
    }
    XCTAssertEqual(r.question, "what did I do")
    XCTAssertEqual(r.period, .today)
    XCTAssertNil(r.preferredModel)
  }

  func testTrimsQuestion() {
    guard case .ok(let r) = AskParams.decode(arguments: ["question": "  hi  "]) else {
      return XCTFail()
    }
    XCTAssertEqual(r.question, "hi")
  }

  func testParsesPeriodAndModel() {
    guard
      case .ok(let r) = AskParams.decode(arguments: [
        "question": "q", "period": "last_7_days", "model": "sonnet",
      ])
    else { return XCTFail() }
    XCTAssertEqual(r.period, .last7Days)
    XCTAssertEqual(r.preferredModel, .sonnet)
  }

  func testRejectsBadPeriod() {
    guard case .error = AskParams.decode(arguments: ["question": "q", "period": "this_month"]) else {
      return XCTFail("unknown period must error")
    }
  }

  func testRejectsBadModel() {
    guard case .error = AskParams.decode(arguments: ["question": "q", "model": "gpt"]) else {
      return XCTFail("unknown model must error")
    }
  }
}
