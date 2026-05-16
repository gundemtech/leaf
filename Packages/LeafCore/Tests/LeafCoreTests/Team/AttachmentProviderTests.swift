//
//  AttachmentProviderTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 B.7 — LeafLinkedEventCard binding sanity:
//  verifies that AttachmentProvider + AttachmentMetadata + CrossPostLogRow
//  compile cleanly together and their expected data flows are coherent.
//  (No SwiftUI in LeafCoreTests — atom compile verification is covered by
//  the Leaf scheme xcodebuild pass in the task checklist.)
//

import XCTest
@testable import LeafCore

/// Binding sanity: simulate the data shape LeafLinkedEventCard receives
/// so that a breaking API change in value types surfaces here before the
/// UI layer.
final class AttachmentProviderTests: XCTestCase {

    // MARK: - Provider ↔ AttachmentMetadata coherence

    func testAllProviders_CanBePairedWithAttachmentMetadata() {
        let url = URL(string: "https://example.com")!
        let providers: [AttachmentProvider] = [.github, .linear, .slack]

        for provider in providers {
            let meta = AttachmentMetadata(
                title: "Test attachment for \(provider.rawValue)",
                statusLabel: "open",
                statusColorKey: .open,
                authorDisplayName: "alice",
                createdAtMs: 0,
                externalURL: url
            )
            // Confirm the metadata is structurally valid for any provider
            XCTAssertFalse(meta.title.isEmpty)
            XCTAssertEqual(meta.statusColorKey, .open)
        }
    }

    // MARK: - CrossPostLogRow ↔ AttachmentProvider coherence

    func testCrossPostPlatformMatchesProviderRawValue() throws {
        let url = URL(string: "https://slack.com/archives/C123/p456")!
        let row = try CrossPostLogRow(
            messageID: "msg-abc",
            platform: AttachmentProvider.slack.rawValue,
            externalRef: "#leaf-architecture",
            externalURL: url,
            postedAtMs: 0,
            errorText: nil
        )
        XCTAssertEqual(row.platform, "slack")
    }

    // MARK: - StatusColorKey semantic coverage

    /// Ensure all StatusColorKey cases have valid raw values for JSON serialisation —
    /// required for Codable storage in messages_mirror.payload_json.
    func testStatusColorKey_AllRawValuesNonEmpty() throws {
        let allKeys: [StatusColorKey] = [.open, .closed, .merged, .inProgress, .completed, .blocked, .neutral]
        for key in allKeys {
            XCTAssertFalse(key.rawValue.isEmpty, "\(key) has empty rawValue")
        }
    }

    /// inProgress raw value must round-trip through JSON with camelCase preserved
    /// (Swift Codable default uses rawValue as-is; no key strategy applied).
    func testStatusColorKey_InProgressCamelCase() {
        XCTAssertEqual(StatusColorKey.inProgress.rawValue, "inProgress")
    }
}
