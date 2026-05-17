import XCTest
@testable import LeafCore

/// ADR-010 walkback fence over the 6 new Work State public types — asserts
/// no property label matches forbidden substrings carried by upstream payload
/// fields we MUST NOT relay through the public surface. Mirrors P2-collapsed
/// `SurfaceCardPayloadWalkbackTests` (different branch, same pattern).
final class WorkStatePayloadWalkbackTests: XCTestCase {

    private let forbiddenSubstrings: [String] = [
        "message_body",
        "email_subject",
        "prompt",
        "tool_response",
        "command",
        "tool_input",
        "content",
        "thinking",
        "signature",
        "iterations",
        "old_string",
        "new_string",
        // Generic forbidden — match against data-field names:
        "body",
        "preview",
        "output",
    ]

    private func assertNoForbiddenLabels<T>(_ value: T, file: StaticString = #filePath, line: UInt = #line) {
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            guard let label = child.label?.lowercased() else { continue }
            for forbidden in forbiddenSubstrings {
                XCTAssertFalse(
                    label.contains(forbidden),
                    "Property `\(child.label ?? "?")` of \(T.self) contains forbidden substring `\(forbidden)`. " +
                    "ADR-010 walkback violated.",
                    file: file, line: line
                )
            }
        }
    }

    // MARK: - Negative fence (no forbidden substrings)

    func testWorkStateSummary_propertyLabels_haveNoForbiddenSubstrings() {
        assertNoForbiddenLabels(WorkStateSummary.empty)
    }

    func testDecision_propertyLabels_haveNoForbiddenSubstrings() {
        let d = Decision(id: 0, excerpt: "", topicKeywords: [],
                         confidence: 0, detectedAtMs: 0, sourceEventId: nil)
        assertNoForbiddenLabels(d)
    }

    func testOpenQuestion_propertyLabels_haveNoForbiddenSubstrings() {
        let q = OpenQuestion(id: 0, excerpt: "", alternatives: [],
                             contextRef: nil, openedAtMs: 0,
                             resolvedAtMs: nil, resolvedBySourceEventId: nil)
        assertNoForbiddenLabels(q)
    }

    func testBlocker_propertyLabels_haveNoForbiddenSubstrings() {
        let b = Blocker(id: 0, targetKind: .linearIssue, targetRef: "",
                        blockerKind: .linearStuck, excerpt: "",
                        startedAtMs: 0, resolvedAtMs: nil)
        assertNoForbiddenLabels(b)
    }

    func testWhereStoppedSnapshot_propertyLabels_haveNoForbiddenSubstrings() {
        let s = WhereStoppedSnapshot(id: 0, generatedAtMs: 0,
                                     anchorEventId: nil, excerpt: "",
                                     wipSignals: [])
        assertNoForbiddenLabels(s)
    }

    func testContextRef_associatedValueLabels_haveNoForbiddenSubstrings() {
        assertNoForbiddenLabels(ContextRef.slackThread(ts: "x"))
        assertNoForbiddenLabels(ContextRef.linearIssue(ref: "x"))
        assertNoForbiddenLabels(ContextRef.githubPR(ref: "x"))
    }

    // MARK: - Positive schema lock-in

    func testWorkStateSummary_schema_lockedIn() {
        let labels = Mirror(reflecting: WorkStateSummary.empty).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), [
            "openQuestionsCount",
            "openBlockersCount",
            "lastDecisionExcerpt",
            "lastDecisionAgeMs",
        ])
    }

    func testDecision_schema_lockedIn() {
        let d = Decision(id: 0, excerpt: "", topicKeywords: [],
                         confidence: 0, detectedAtMs: 0, sourceEventId: nil)
        let labels = Mirror(reflecting: d).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), [
            "id", "excerpt", "topicKeywords", "confidence",
            "detectedAtMs", "sourceEventId"
        ])
    }

    func testOpenQuestion_schema_lockedIn() {
        let q = OpenQuestion(id: 0, excerpt: "", alternatives: [],
                             contextRef: nil, openedAtMs: 0,
                             resolvedAtMs: nil, resolvedBySourceEventId: nil)
        let labels = Mirror(reflecting: q).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), [
            "id", "excerpt", "alternatives", "contextRef",
            "openedAtMs", "resolvedAtMs", "resolvedBySourceEventId"
        ])
    }

    func testBlocker_schema_lockedIn() {
        let b = Blocker(id: 0, targetKind: .linearIssue, targetRef: "",
                        blockerKind: .linearStuck, excerpt: "",
                        startedAtMs: 0, resolvedAtMs: nil)
        let labels = Mirror(reflecting: b).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), [
            "id", "targetKind", "targetRef", "blockerKind",
            "excerpt", "startedAtMs", "resolvedAtMs"
        ])
    }

    func testWhereStoppedSnapshot_schema_lockedIn() {
        let s = WhereStoppedSnapshot(id: 0, generatedAtMs: 0,
                                     anchorEventId: nil, excerpt: "",
                                     wipSignals: [])
        let labels = Mirror(reflecting: s).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), [
            "id", "generatedAtMs", "anchorEventId", "excerpt", "wipSignals"
        ])
    }
}
