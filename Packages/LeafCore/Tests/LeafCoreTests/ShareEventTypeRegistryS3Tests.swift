import XCTest
@testable import LeafCore

/// Phase Track-4 S3 — verifies registry expansion: 13 new event_kind cases all
/// land with `defaultEnabled: false` per ADR-020 (capture-everything locally,
/// share-selectively).
final class ShareEventTypeRegistryS3Tests: XCTestCase {

    private let s3RawValues: Set<String> = [
        "intensity_snapshot", "intensity_bucket_dropped",
        "audio_route_changed",
        "mic_in_use_entered", "mic_in_use_exited",
        "display_connected", "display_disconnected",
        "vpn_state_changed",
        "wifi_state_changed",
        "clipboard_event_count",
        "screenshot_taken",
        "download_added",
        "trash_changed"
    ]

    func testS3KeysRegistered() {
        let allRawValues = Set(ShareEventTypeKey.allCases.map { $0.rawValue })
        for raw in s3RawValues {
            XCTAssertTrue(allRawValues.contains(raw),
                          "S3 raw value \(raw) must appear in ShareEventTypeKey")
        }
        XCTAssertEqual(s3RawValues.count, 13, "S3 contract: 13 new keys")
    }

    func testRegistrySizeIs152() {
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 156)
        XCTAssertEqual(ShareEventTypeDefaults.all.count, 156)
    }

    func testAllS3KeysDefaultOff() {
        for entry in ShareEventTypeDefaults.all where s3RawValues.contains(entry.key.rawValue) {
            XCTAssertFalse(entry.defaultEnabled,
                "S3 key \(entry.key.rawValue) must default to OFF per ADR-020")
        }
    }

    func testS3RawValueLiterals() {
        XCTAssertEqual(ShareEventTypeKey.intensitySnapshot.rawValue, "intensity_snapshot")
        XCTAssertEqual(ShareEventTypeKey.intensityBucketDropped.rawValue, "intensity_bucket_dropped")
        XCTAssertEqual(ShareEventTypeKey.audioRouteChanged.rawValue, "audio_route_changed")
        XCTAssertEqual(ShareEventTypeKey.micInUseEntered.rawValue, "mic_in_use_entered")
        XCTAssertEqual(ShareEventTypeKey.micInUseExited.rawValue, "mic_in_use_exited")
        XCTAssertEqual(ShareEventTypeKey.displayConnected.rawValue, "display_connected")
        XCTAssertEqual(ShareEventTypeKey.displayDisconnected.rawValue, "display_disconnected")
        XCTAssertEqual(ShareEventTypeKey.vpnStateChanged.rawValue, "vpn_state_changed")
        XCTAssertEqual(ShareEventTypeKey.wifiStateChanged.rawValue, "wifi_state_changed")
        XCTAssertEqual(ShareEventTypeKey.clipboardEventCount.rawValue, "clipboard_event_count")
        XCTAssertEqual(ShareEventTypeKey.screenshotTaken.rawValue, "screenshot_taken")
        XCTAssertEqual(ShareEventTypeKey.downloadAdded.rawValue, "download_added")
        XCTAssertEqual(ShareEventTypeKey.trashChanged.rawValue, "trash_changed")
    }
}
