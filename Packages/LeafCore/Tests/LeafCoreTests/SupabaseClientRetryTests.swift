//
//  SupabaseClientRetryTests.swift
//  LeafCoreTests
//
//  Phase M-I (optimization-tier-m.md). Coverage:
//  - Pure classifier (9 tests, no actor, no URLSession)
//  - performHTTP integration via MockURLProtocol (added in Task 2 / Task 3)
//

import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientRetryTests: XCTestCase {
  // MARK: - Pure classifier

  private let policy = RetryPolicy(
    maxAttempts: 4,
    delays: [.milliseconds(200), .seconds(1), .seconds(3)],
    jitterFraction: 0.25
  )

  private func makeResp(_ status: Int, url: URL = URL(string: "https://t.example/x")!)
    -> HTTPURLResponse
  {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
  }

  func test_classifier_giveUp_when_attempt_at_max() {
    let d = classify(
      response: makeResp(503), error: nil, attempt: 3, policy: policy,
      retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
    )
    XCTAssertEqual(d, .giveUp)
  }

  func test_classifier_retries_5xx_with_schedule_delay() {
    for status in [500, 502, 503, 504, 505, 506, 507, 508, 510, 511] {
      let d = classify(
        response: makeResp(status), error: nil, attempt: 0, policy: policy,
        retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
      )
      XCTAssertEqual(d, .retry(after: .milliseconds(200)), "status=\(status)")
    }
  }

  func test_classifier_giveUp_on_501_not_implemented() {
    let d = classify(
      response: makeResp(501), error: nil, attempt: 0, policy: policy,
      retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
    )
    XCTAssertEqual(d, .giveUp)
  }

  func test_classifier_429_with_retryAfterHint_uses_hint() {
    let d = classify(
      response: makeResp(429), error: nil, attempt: 0, policy: policy,
      retryAfterHint: .seconds(2), nextDelayJitterMultiplier: 1.0
    )
    XCTAssertEqual(d, .retry(after: .seconds(2)))
  }

  func test_classifier_429_without_hint_uses_schedule() {
    let d = classify(
      response: makeResp(429), error: nil, attempt: 1, policy: policy,
      retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
    )
    XCTAssertEqual(d, .retry(after: .seconds(1)))  // schedule[1] = 1s
  }

  func test_classifier_retries_transient_urlErrors() {
    let codes: [URLError.Code] = [
      .timedOut, .networkConnectionLost, .notConnectedToInternet,
      .dnsLookupFailed, .cannotConnectToHost, .cannotFindHost,
    ]
    for code in codes {
      let d = classify(
        response: nil, error: URLError(code), attempt: 0, policy: policy,
        retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
      )
      XCTAssertEqual(d, .retry(after: .milliseconds(200)), "code=\(code)")
    }
  }

  func test_classifier_giveUp_on_non_transient_urlErrors() {
    let codes: [URLError.Code] = [
      .cancelled, .userCancelledAuthentication, .secureConnectionFailed,
      .clientCertificateRejected, .badServerResponse,
    ]
    for code in codes {
      let d = classify(
        response: nil, error: URLError(code), attempt: 0, policy: policy,
        retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
      )
      XCTAssertEqual(d, .giveUp, "code=\(code)")
    }
  }

  func test_classifier_giveUp_on_4xx() {
    for status in [400, 401, 403, 404, 409, 410, 422] {
      let d = classify(
        response: makeResp(status), error: nil, attempt: 0, policy: policy,
        retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
      )
      XCTAssertEqual(d, .giveUp, "status=\(status)")
    }
  }

  func test_classifier_jitter_applies_to_schedule_not_to_hint() {
    // Schedule[0] = 200ms, multiplier = 1.5 → 300ms.
    let schedDecision = classify(
      response: makeResp(502), error: nil, attempt: 0, policy: policy,
      retryAfterHint: nil, nextDelayJitterMultiplier: 1.5
    )
    XCTAssertEqual(schedDecision, .retry(after: .milliseconds(300)))

    // Hint = 2s, multiplier ignored (verbatim).
    let hintDecision = classify(
      response: makeResp(429), error: nil, attempt: 0, policy: policy,
      retryAfterHint: .seconds(2), nextDelayJitterMultiplier: 1.5
    )
    XCTAssertEqual(hintDecision, .retry(after: .seconds(2)))
  }
}
