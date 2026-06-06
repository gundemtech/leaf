import XCTest

@testable import LeafCore

/// P5 — the attestation audit contract (verdict-only, content-free). The concrete
/// DB sink + M033 table are deferred to the production-wiring phase; the protocol +
/// entry + a spy prove the audit-first discipline now (used by AttestedSummarizer).
final class AttestationAuditTests: XCTestCase {
  func testEntryFromVerdictMapsBooleansOnly() {
    let verdict = AttestationVerdict(
      isVerified: true, assurance: .poc, boundPublicKeySPKI: Data([1]),
      measurementMatched: true, freshnessOK: true, signatureOK: true, spkiBindingOK: false)
    let entry = AttestationAuditEntry(
      occurredAtMs: 5, path: InferencePath.attested.auditLabel, model: "attestedOpenWeight",
      endpointLabel: "tinfoil-poc", sourceSummary: "facts=3", verdict: verdict)
    XCTAssertEqual(entry.occurredAtMs, 5)
    XCTAssertEqual(entry.path, "attested")
    XCTAssertEqual(entry.assurance, "poc")
    XCTAssertTrue(entry.verified)
    XCTAssertFalse(entry.spkiBindingOK)
    XCTAssertEqual(entry.endpointLabel, "tinfoil-poc")
    XCTAssertEqual(entry.sourceSummary, "facts=3")
  }

  func testSpySinkConformsAndRecords() async throws {
    actor SpySink: AttestationAuditSink {
      private(set) var entries: [AttestationAuditEntry] = []
      func record(_ entry: AttestationAuditEntry) async throws { entries.append(entry) }
    }
    let sink = SpySink()
    let e = AttestationAuditEntry(
      occurredAtMs: 1, path: "attested", model: "attestedOpenWeight", endpointLabel: "x",
      sourceSummary: "s", verdict: .failClosed)
    try await sink.record(e)
    let count = await sink.entries.count
    XCTAssertEqual(count, 1)
    let recorded = await sink.entries[0]
    XCTAssertFalse(recorded.verified)  // failClosed → over-record an unverified attempt
  }
}
