import XCTest
@testable import LeafCore

/// Phase Track-4 S3 — defence-in-depth privacy walkback против CGEventTap
/// content reads. Three layers:
///   1) Source-grep на `CGEventTapCollector.swift` — forbidden API
///      substring count == 0.
///   2) Source-grep на `IntensityBucketAccumulator.swift` — same set.
///   3) Runtime payload audit — `IntensityBucketSnapshot.toRawEventPayload()`
///      keys subset of whitelist `{event_kind, keystroke_count, mouse_move_count,
///      app_switch_count, foreground_app, state}`.
///
/// Compile-time guard via IntensityBucketSnapshot fields (counter-only) +
/// CGEvent callback's mask-based discrimination — primary safety. These
/// tests catch a future bypass где разработчик добавляет forbidden API call
/// без disabling tests.
final class CGEventTapNoContentLeakageTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // LeafCoreTests/
            .deletingLastPathComponent()    // Tests/
            .deletingLastPathComponent()    // LeafCore/
            .deletingLastPathComponent()    // Packages/
            .deletingLastPathComponent()    // <repo root>/
    }

    private func readSource(_ relPath: String) throws -> String {
        let url = repoRoot().appendingPathComponent(relPath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func stripComments(_ src: String) -> String {
        var s = src.replacingOccurrences(
            of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        s = s.replacingOccurrences(
            of: "//[^\\n]*", with: "", options: .regularExpression)
        return s
    }

    private let forbiddenContentTokens: [String] = [
        ".keyboardEventKeycode",
        "keyboardEventKeycode",
        ".unicodeStringValue",
        "getUnicodeString",
        ".modifierFlags",
        ".location",
        "event.location",
        ".mouseLocation"
    ]

    func testCGEventTapCollectorSourceGrep() throws {
        let src = stripComments(try readSource("LeafAgent/Collectors/CGEventTapCollector.swift"))
        for token in forbiddenContentTokens {
            XCTAssertFalse(src.contains(token),
                "CGEventTapCollector.swift must NOT contain forbidden content-read API: \(token)")
        }
    }

    func testIntensityBucketAccumulatorSourceGrep() throws {
        let src = stripComments(try readSource("Packages/LeafCore/Sources/LeafCore/OS/IntensityBucketAccumulator.swift"))
        for token in forbiddenContentTokens {
            XCTAssertFalse(src.contains(token),
                "IntensityBucketAccumulator.swift must NOT contain forbidden token: \(token)")
        }
    }

    func testActivePayloadKeysWhitelisted() {
        let snap = IntensityBucketSnapshot(
            minuteBucketMs: 60_000,
            keystrokes: 7, mouseMoves: 14, appSwitches: 2,
            foregroundApp: "com.apple.dt.Xcode",
            droppedReason: nil
        )
        let allowedKeys: Set<String> = [
            "event_kind",
            Schema.EventPayloadKeys.keystrokeCount,
            Schema.EventPayloadKeys.mouseMoveCount,
            Schema.EventPayloadKeys.appSwitchCount,
            Schema.EventPayloadKeys.foregroundApp
        ]
        let payloadKeys = Set(snap.toRawEventPayload().keys)
        XCTAssertTrue(payloadKeys.isSubset(of: allowedKeys),
            "Active snapshot payload keys must be subset of \(allowedKeys), got \(payloadKeys)")
    }

    func testDroppedPayloadKeysWhitelisted() {
        let snap = IntensityBucketSnapshot(
            minuteBucketMs: 60_000,
            keystrokes: 0, mouseMoves: 0, appSwitches: 0,
            foregroundApp: nil,
            droppedReason: .sleeping
        )
        let allowedKeys: Set<String> = ["event_kind", "state"]
        let payloadKeys = Set(snap.toRawEventPayload().keys)
        XCTAssertTrue(payloadKeys.isSubset(of: allowedKeys),
            "Dropped snapshot payload keys must be subset of \(allowedKeys), got \(payloadKeys)")
    }

    /// CGEventTapCollector tap mask must include ONLY whitelisted CGEventType
    /// raw values: .keyDown(10), .leftMouseDown(1), .rightMouseDown(3),
    /// .mouseMoved(5), .leftMouseDragged(6), .rightMouseDragged(7),
    /// .scrollWheel(22). Source-grep catches any new event-type addition
    /// (e.g. `.keyUp` — would expose key state pairs).
    func testTapMaskWhitelisted() throws {
        let src = try readSource("LeafAgent/Collectors/CGEventTapCollector.swift")
        let allowedRawNames = [
            ".keyDown.rawValue",
            ".leftMouseDown.rawValue",
            ".rightMouseDown.rawValue",
            ".mouseMoved.rawValue",
            ".leftMouseDragged.rawValue",
            ".rightMouseDragged.rawValue",
            ".scrollWheel.rawValue"
        ]
        for needle in allowedRawNames {
            XCTAssertTrue(src.contains(needle),
                "CGEventTapCollector tap mask must include \(needle)")
        }
        // Forbidden event types — would expose key state pairs / location data.
        let forbiddenInMask = [
            ".keyUp.rawValue",
            ".flagsChanged.rawValue",
            ".otherMouseDown.rawValue",
            ".otherMouseUp.rawValue",
            ".tabletPointer.rawValue",
            ".tabletProximity.rawValue"
        ]
        for needle in forbiddenInMask {
            XCTAssertFalse(src.contains(needle),
                "CGEventTapCollector tap mask must NOT include \(needle)")
        }
    }
}
