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

  // P5 — the verifiable path serves only an open-weight model; any Anthropic
  // preference is ignored (Claude is not attestable).
  func testAttestedPathForcesOpenWeightIgnoringPreference() {
    XCTAssertEqual(DefaultModelGate().model(path: .attested, preferred: nil), .attestedOpenWeight)
    XCTAssertEqual(DefaultModelGate().model(path: .attested, preferred: .opus), .attestedOpenWeight)
    XCTAssertEqual(DefaultModelGate().model(path: .attested, preferred: .haiku), .attestedOpenWeight)
  }

  // P5 — audit label is an exhaustive mapping (replaces the `== .byok ? :` ternaries
  // in AIDetailAnswerer/HandoffDrafter that silently mislabelled .attested).
  func testInferencePathAuditLabel() {
    XCTAssertEqual(InferencePath.byok.auditLabel, "byok")
    XCTAssertEqual(InferencePath.aiIncluded.auditLabel, "ai_included")
    XCTAssertEqual(InferencePath.attested.auditLabel, "attested")
  }
}
