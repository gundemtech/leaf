import XCTest
@testable import LeafCore

/// Phase Track-4 S3 — generic per-collector source-grep. Catches the
/// boundary-read bypass где разработчик добавляет forbidden API call
/// в S3 collector. Compile-time guard via state machines + matchers —
/// primary safety; this test is the secondary belt+suspenders.
final class S3CollectorSourceGrepTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    private func grepForbiddenList(_ relPath: String, _ forbidden: [String]) throws {
        let src = stripComments(try readSource(relPath))
        for token in forbidden {
            XCTAssertFalse(src.contains(token),
                "\(relPath) must NOT contain forbidden API call: \(token)")
        }
    }

    /// ClipboardCollector reads ONLY `.changeCount`. NEVER reads pasteboard
    /// items / strings / data / property list (ADR-010 Won't-list — clipboard
    /// → count only).
    func testClipboardCollectorReadsNoPasteboardContent() throws {
        try grepForbiddenList("LeafAgent/Collectors/ClipboardCollector.swift", [
            "pasteboardItems",
            "string(forType:",
            "data(forType:",
            "propertyList(forType:",
            "types(forType:"
        ])
    }

    /// MicInUseCollector listens к `kAudioDevicePropertyDeviceIsRunningSomewhere`.
    /// NEVER imports AVFoundation / opens AVCaptureSession / AVAudioRecorder
    /// (audio samples capture).
    func testMicInUseCollectorReadsNoAudioSamples() throws {
        try grepForbiddenList("LeafAgent/Collectors/MicInUseCollector.swift", [
            "AVCaptureDevice",
            "AVCaptureSession",
            "AVAudioRecorder",
            "AVAudioEngine"
        ])
    }

    /// AudioRouteCollector reads ONLY `kAudioDevicePropertyTransportType` enum.
    /// NEVER reads `kAudioDevicePropertyDeviceName` / manufacturer / model UID.
    func testAudioRouteCollectorReadsNoDeviceName() throws {
        try grepForbiddenList("LeafAgent/Collectors/AudioRouteCollector.swift", [
            "kAudioDevicePropertyDeviceName",
            "kAudioObjectPropertyName",
            "kAudioDevicePropertyDeviceManufacturer",
            "kAudioDevicePropertyModelUID"
        ])
    }

    /// WiFiCollector reads ONLY `.powerOn()` + `.interfaceMode()`. NEVER reads
    /// `.ssid()` / `.bssid()` (Location TCC + PII) — explicit OQ-S3-3 decision.
    func testWiFiCollectorReadsNoSSID() throws {
        try grepForbiddenList("LeafAgent/Collectors/WiFiCollector.swift", [
            ".ssid()",
            ".bssid()",
            "requestLocationAuthorization",
            "CLLocationManager"
        ])
    }

    /// DisplayCollector listens на reconfiguration; NEVER captures pixels via
    /// CGDisplayCreateImage / CGWindowListCreateImage / ScreenCaptureKit.
    func testDisplayCollectorReadsNoPixels() throws {
        try grepForbiddenList("LeafAgent/Collectors/DisplayCollector.swift", [
            "CGDisplayCreateImage",
            "CGWindowListCreateImage",
            "ScreenCaptureKit",
            "SCStreamConfiguration"
        ])
    }

    /// LocalFilesWatcher emits filenames ONLY. NEVER reads file contents.
    func testLocalFilesWatcherReadsNoFileContents() throws {
        try grepForbiddenList("LeafAgent/Collectors/LocalFilesWatcher.swift", [
            "Data(contentsOf:",
            "String(contentsOf:",
            "FileHandle(forReadingAt:",
            "FileManager.default.contents(atPath:",
            ".contents(atPath:"
        ])
    }

    /// VPNCollector reads `connection.status` ONLY. NEVER reads serverAddress
    /// / passwordReference / shared secret (credential surface).
    func testVPNCollectorReadsNoCredentials() throws {
        try grepForbiddenList("LeafAgent/Collectors/VPNCollector.swift", [
            "serverAddress",
            "passwordReference",
            "sharedSecretReference",
            "username"
        ])
    }

    /// CGEventTapCollector — duplicate fence (redundant с
    /// CGEventTapNoContentLeakageTests, intentional belt+suspenders).
    func testCGEventTapCollectorReadsNoEventContent() throws {
        try grepForbiddenList("LeafAgent/Collectors/CGEventTapCollector.swift", [
            ".keyboardEventKeycode",
            ".unicodeStringValue",
            ".modifierFlags",
            ".mouseLocation"
        ])
    }
}
