//
//  SurfaceCardPayloadWalkbackTests.swift
//  Track 7 P2-collapsed — structural fence for the 5 new Home card payloads
//  and breakdowns. Mirror-based: enumerates every stored property name and
//  asserts none match the ADR-010 forbidden-fields list. Pairs with the
//  static grep fence in spec §6 AC-4.
//
//  Adding a new field to any of these payloads is auto-covered: Mirror
//  surfaces the new label, and the assertion fails if it overlaps the
//  forbidden set.
//

import XCTest

@testable import LeafCore

final class SurfaceCardPayloadWalkbackTests: XCTestCase {

    /// ADR-010 / spec §6 AC-4 — substrings that must not appear in any
    /// property name on the 5 new payload or breakdown types.
    private static let forbiddenFieldSubstrings: [String] = [
        "tool_input", "tool_response", "toolInput", "toolResponse",
        "command",
        "absolute_path", "absolutePath",
        "note_body", "noteBody",
        "email_subject", "emailSubject",
        "file_contents", "fileContents",
        "attendee_email", "attendeeEmail",
        "debugger_state", "debuggerState",
        "raw_url", "rawURL", "rawUrl",
        "preview",
        "body",
        "content",
        "thinking",
        "signature",
        "message",
    ]

    // MARK: - Payloads

    func testXcodeCardPayload_propertiesAreWalkbackClean() {
        let payload = XcodeCardPayload(
            buildCount: 0, testRunCount: 0,
            buildSuccessCount: 0, buildFailureCount: 0,
            schemesTouchedCount: 0, dailyBuilds: []
        )
        assertWalkbackClean(payload, type: "XcodeCardPayload")
    }

    func testIDEsCardPayload_propertiesAreWalkbackClean() {
        let payload = IDEsCardPayload(
            fileEventCount: 0, workspaceCount: 0,
            vscodeFamilyEventCount: 0, jetbrainsEventCount: 0,
            fallbackTitleCount: 0, dailyEvents: []
        )
        assertWalkbackClean(payload, type: "IDEsCardPayload")
    }

    func testBrowsersCardPayload_propertiesAreWalkbackClean() {
        let payload = BrowsersCardPayload(
            pageCount: 0, domainCount: 0,
            safariCount: 0, chromeCount: 0, arcCount: 0,
            bookmarksAddedCount: 0, dailyNavigations: []
        )
        assertWalkbackClean(payload, type: "BrowsersCardPayload")
    }

    func testZoomCardPayload_propertiesAreWalkbackClean() {
        let payload = ZoomCardPayload(
            meetingCount: 0, totalDurationSeconds: 0,
            calendarLinkedCount: 0, adHocCount: 0,
            dailyMinutes: []
        )
        assertWalkbackClean(payload, type: "ZoomCardPayload")
    }

    func testGoogleCalendarCardPayload_propertiesAreWalkbackClean() {
        let payload = GoogleCalendarCardPayload(
            focusBlockCount: 0, focusDurationSeconds: 0,
            oooBlockCount: 0, workingLocationCount: 0,
            dailyFocusMinutes: []
        )
        assertWalkbackClean(payload, type: "GoogleCalendarCardPayload")
    }

    // MARK: - Breakdowns

    func testXcodeActivityBreakdown_propertiesAreWalkbackClean() {
        assertWalkbackClean(XcodeActivityBreakdown.empty, type: "XcodeActivityBreakdown")
    }

    func testIDEsActivityBreakdown_propertiesAreWalkbackClean() {
        assertWalkbackClean(IDEsActivityBreakdown.empty, type: "IDEsActivityBreakdown")
    }

    func testBrowsersActivityBreakdown_propertiesAreWalkbackClean() {
        assertWalkbackClean(BrowsersActivityBreakdown.empty, type: "BrowsersActivityBreakdown")
    }

    func testZoomActivityBreakdown_propertiesAreWalkbackClean() {
        assertWalkbackClean(ZoomActivityBreakdown.empty, type: "ZoomActivityBreakdown")
    }

    func testGoogleCalendarActivityBreakdown_propertiesAreWalkbackClean() {
        assertWalkbackClean(GoogleCalendarActivityBreakdown.empty, type: "GoogleCalendarActivityBreakdown")
    }

    // MARK: - Nested

    func testDomainCountEntry_propertiesAreWalkbackClean() {
        let entry = DomainCountEntry(domain: "example.com", count: 1)
        assertWalkbackClean(entry, type: "DomainCountEntry")
    }

    // MARK: - Schema sanity (positive assertions)

    /// Locks in the spec §3 contract so a future field rename doesn't silently
    /// pass the walkback while breaking downstream views.
    func testXcodeCardPayload_hasExpectedProperties() {
        let payload = XcodeCardPayload(
            buildCount: 0, testRunCount: 0,
            buildSuccessCount: 0, buildFailureCount: 0,
            schemesTouchedCount: 0, dailyBuilds: []
        )
        let labels = Set(propertyLabels(of: payload))
        XCTAssertEqual(
            labels,
            [
                "buildCount", "testRunCount",
                "buildSuccessCount", "buildFailureCount",
                "schemesTouchedCount", "dailyBuilds",
            ])
    }

    // MARK: - Helpers

    private func assertWalkbackClean<T>(_ value: T, type: String, file: StaticString = #filePath, line: UInt = #line) {
        let labels = propertyLabels(of: value)
        for label in labels {
            for forbidden in Self.forbiddenFieldSubstrings {
                if label.range(of: forbidden, options: .caseInsensitive) != nil {
                    XCTFail(
                        "\(type) property '\(label)' contains forbidden ADR-010 substring '\(forbidden)'",
                        file: file, line: line
                    )
                }
            }
        }
    }

    private func propertyLabels<T>(of value: T) -> [String] {
        Mirror(reflecting: value).children.compactMap { $0.label }
    }
}
