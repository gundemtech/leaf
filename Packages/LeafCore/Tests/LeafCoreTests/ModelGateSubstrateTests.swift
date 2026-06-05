import XCTest

@testable import LeafCore

final class ModelGateSubstrateTests: XCTestCase {
  func testDefaultGateReturnsHaikuWhenNoPreference() {
    XCTAssertEqual(DefaultModelGate().model(path: .byok, preferred: nil), .haiku)
    XCTAssertEqual(DefaultModelGate().model(path: .aiIncluded, preferred: nil), .haiku)
  }

  func testDefaultGateHonorsPreferenceOnByok() {
    XCTAssertEqual(DefaultModelGate().model(path: .byok, preferred: .sonnet), .sonnet)
    XCTAssertEqual(DefaultModelGate().model(path: .byok, preferred: .opus), .opus)
  }

  func testDefaultGateClampsOpusOnAIIncluded() {
    XCTAssertEqual(DefaultModelGate().model(path: .aiIncluded, preferred: .opus), .sonnet)
  }

  func testModelGateMoatSubstrateIsDefault() {
    let gate = ModelGateMoat.publicSubstrate.gate
    XCTAssertEqual(gate.model(path: .byok, preferred: nil), .haiku)
    XCTAssertEqual(gate.model(path: .aiIncluded, preferred: .opus), .sonnet)
  }

  func testFakeGateProvesSeamInjectable() {
    struct FakeGate: ModelGate {
      func model(path: InferencePath, preferred: SummarizerModel?) -> SummarizerModel { .sonnet }
    }
    XCTAssertEqual(ModelGateMoat(gate: FakeGate()).gate.model(path: .byok, preferred: nil), .sonnet)
  }
}
