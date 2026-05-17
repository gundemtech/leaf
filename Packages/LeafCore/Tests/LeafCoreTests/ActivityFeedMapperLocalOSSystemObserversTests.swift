// Phase Track-4 S3 — system observers visible kinds (audio / mic / display / VPN /
// Wi-Fi / screenshot / download / trash). Split from ActivityFeedMapperLocalOSTests.swift
// for type_body_length / file_length.

import XCTest

@testable import LeafCore

final class ActivityFeedMapperLocalOSSystemObserversTests: XCTestCase {
    private typealias Support = ActivityFeedMapperLocalOSTestSupport

    private func map(
        kind: String,
        signalType: String = "context",
        bundleID: String? = nil,
        extras: [String: String] = [:]
    ) -> ActivityFeedEntry? {
        Support.map(kind: kind, signalType: signalType, bundleID: bundleID, extras: extras)
    }

    func testAudioRouteChanged() {
        // AudioRouteCollector emits `audio_route` (Schema.EventPayloadKeys.audioRoute)
        // carrying AudioRouteCategory enum rawValue (transport type only,
        // never device name — ADR-010).
        let entry = map(
            kind: "audio_route_changed", signalType: "context",
            extras: ["audio_route": "headphones"])
        XCTAssertEqual(entry?.primaryText, "Audio route: headphones")
    }

    func testMicInUseEntered() {
        XCTAssertEqual(map(kind: "mic_in_use_entered")?.primaryText, "Mic on")
    }

    func testMicInUseExited() {
        XCTAssertEqual(map(kind: "mic_in_use_exited")?.primaryText, "Mic off")
    }

    func testDisplayConnected() {
        // DisplayCollector emits payload {event_kind, state} — no count field
        // (`display_count` was never wired). Mapper renders primary only.
        let entry = map(
            kind: "display_connected", signalType: "context",
            extras: ["state": "display_connected"])
        XCTAssertEqual(entry?.primaryText, "Display connected")
        XCTAssertNil(entry?.secondaryText)
    }

    func testDisplayDisconnected() {
        let entry = map(
            kind: "display_disconnected", signalType: "context",
            extras: ["state": "display_disconnected"])
        XCTAssertEqual(entry?.primaryText, "Display disconnected")
        XCTAssertNil(entry?.secondaryText)
    }

    func testVPNStateChanged() {
        let entry = map(
            kind: "vpn_state_changed", signalType: "context",
            extras: ["state": "connected"])
        XCTAssertEqual(entry?.primaryText, "VPN: connected")
    }

    func testWifiStateChanged() {
        let entry = map(
            kind: "wifi_state_changed", signalType: "context",
            extras: ["state": "associated"])
        XCTAssertEqual(entry?.primaryText, "Wi-Fi: associated")
    }

    func testScreenshotTaken() {
        let entry = map(
            kind: "screenshot_taken", signalType: "content",
            extras: ["filename": "Screen Shot 2026-05-13.png"])
        XCTAssertEqual(entry?.primaryText, "Screenshot: Screen Shot 2026-05-13.png")
    }

    func testDownloadAdded() {
        let entry = map(
            kind: "download_added", signalType: "content",
            extras: ["filename": "report.pdf"])
        XCTAssertEqual(entry?.primaryText, "Download: report.pdf")
    }

    func testTrashChangedEmptied() {
        let entry = map(
            kind: "trash_changed", signalType: "context",
            extras: ["action": "emptied"])
        XCTAssertEqual(entry?.primaryText, "Trash emptied")
    }

    func testTrashChangedAdded() {
        let entry = map(
            kind: "trash_changed", signalType: "context",
            extras: ["action": "added"])
        XCTAssertEqual(entry?.primaryText, "Trash items added")
    }
}
