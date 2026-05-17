import XCTest

@testable import LeafCore

/// Phase Track-4 S1 — defence-in-depth: source-grep that S1 collectors never
/// reach for PII OS APIs. Compile-time guard via boundary types
/// (`MeetingObservation` / `FocusObservation`) is the primary safety; this
/// test catches the bypass where a future developer reads PII directly from
/// the OS API at the boundary and copies it into the RawEvent payload.
///
/// File paths are anchored to the package root via `#filePath`-relative
/// lookups — the test resolves
/// `<repo>/Packages/LeafCore/Tests/LeafCoreTests/<this>` and walks up to the
/// repo root, then descends to the collector files.
final class S1CollectorSourceGrepTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LeafCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // LeafCore/
            .deletingLastPathComponent()  // Packages/
            .deletingLastPathComponent()  // <repo root>/
    }

    private func readSource(_ relPath: String) throws -> String {
        let url = repoRoot().appendingPathComponent(relPath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Strip single-line comments (`//` / `///`) and block comments (`/* */`)
    /// from Swift source so grep tests only inspect executable code. Block
    /// comments here are line-anchored — no nesting heuristics, matches the
    /// shape used in S1 collectors.
    private func stripComments(_ src: String) -> String {
        // Block comments first (non-greedy across lines).
        var s = src.replacingOccurrences(
            of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        // Single-line: from `//` to EOL. Also catches `///` doc comments.
        s = s.replacingOccurrences(
            of: "//[^\\n]*", with: "", options: .regularExpression)
        return s
    }

    /// #1 — CalendarCollector NEVER reads EKEvent PII fields. The file's only
    /// purpose is reading EKEvent at the boundary, so any of these property
    /// suffixes has no legitimate use here — the boundary reads ONLY
    /// `.startDate` / `.endDate` / `.isAllDay` / `.status`. Comments stripped
    /// before grep so docstring mentions of PII property names don't trip the
    /// assertion.
    func testCalendarCollectorReadsNoEKEventPIIFields() throws {
        let src = stripComments(try readSource("LeafAgent/Collectors/CalendarCollector.swift"))
        let forbiddenSuffixes = [
            ".title", ".location", ".attendees", ".notes", ".organizer",
        ]
        for pattern in forbiddenSuffixes {
            XCTAssertFalse(
                src.contains(pattern),
                "CalendarCollector.swift code must NOT contain forbidden EKEvent property access: \(pattern)"
            )
        }
        // `.url` is too broad as a bare substring; pin to actual EKEvent-style
        // accessors that would represent the risk.
        for pattern in ["event.url", "item.url", "ekEvent.url"] {
            XCTAssertFalse(
                src.contains(pattern),
                "CalendarCollector.swift code must NOT contain forbidden EKEvent.url access: \(pattern)"
            )
        }
    }

    /// #2 — FocusModeCollector reads only `.isFocused` on INFocusStatus.
    func testFocusModeCollectorReadsOnlyIsFocused() throws {
        let src = stripComments(try readSource("LeafAgent/Collectors/FocusModeCollector.swift"))
        let forbidden = [
            ".identifier",  // future mode-name accessor
            ".reason",
            ".focusModeIdentifier",
        ]
        for pattern in forbidden {
            XCTAssertFalse(
                src.contains(pattern),
                "FocusModeCollector.swift code must NOT contain forbidden access: \(pattern)"
            )
        }
        // Positive — collector MUST read `.isFocused` to function.
        XCTAssertTrue(
            src.contains(".isFocused"),
            "FocusModeCollector.swift must read `.isFocused` (positive baseline)")
    }

    /// #3 — SpacesCollector NEVER captures a space identifier. We allow the
    /// `activeSpaceDidChangeNotification` notification-name token because
    /// subscribing to it is required for the collector to function — what the
    /// won't-list bans is READING the space identifier itself (e.g.
    /// `NSWorkspace.shared.activeSpace`). Comments stripped to keep regex on
    /// executable code only.
    func testSpacesCollectorReadsNoSpaceIdentifier() throws {
        let src = stripComments(try readSource("LeafAgent/Collectors/SpacesCollector.swift"))
        let forbidden = [
            // Reading the actual current Space (banned per won't-list).
            "NSWorkspace.shared.activeSpace ",
            "NSWorkspace.shared.activeSpace.",
            "NSWorkspace.shared.activeSpace\n",
            // Common keys that would hold space identifier data.
            "spaceID", "space_id", ".identifier",
        ]
        for pattern in forbidden {
            XCTAssertFalse(
                src.contains(pattern),
                "SpacesCollector.swift code must NOT contain forbidden access: \(pattern.debugDescription)"
            )
        }
    }
}
