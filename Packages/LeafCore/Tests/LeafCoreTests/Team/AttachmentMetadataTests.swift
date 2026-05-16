//
//  AttachmentMetadataTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 B.7 — AttachmentMetadata value type tests.
//

import XCTest
@testable import LeafCore

final class AttachmentMetadataTests: XCTestCase {

    private let url = URL(string: "https://github.com/org/repo/pull/42")!

    // MARK: - Basic init + accessors

    func testInitAllFields() {
        let meta = AttachmentMetadata(
            title: "Add caching layer",
            statusLabel: "open",
            statusColorKey: .open,
            authorDisplayName: "alice",
            createdAtMs: 1_716_000_000_000,
            externalURL: url
        )
        XCTAssertEqual(meta.title, "Add caching layer")
        XCTAssertEqual(meta.statusLabel, "open")
        XCTAssertEqual(meta.statusColorKey, .open)
        XCTAssertEqual(meta.authorDisplayName, "alice")
        XCTAssertEqual(meta.createdAtMs, 1_716_000_000_000)
        XCTAssertEqual(meta.externalURL, url)
    }

    func testInitOptionalStatusLabel_Nil() {
        let meta = AttachmentMetadata(
            title: "Loading…",
            statusLabel: nil,
            statusColorKey: .neutral,
            authorDisplayName: "",
            createdAtMs: 0,
            externalURL: url
        )
        XCTAssertNil(meta.statusLabel)
    }

    // MARK: - StatusColorKey exhaustiveness

    func testAllStatusColorKeyCases() {
        let cases: [StatusColorKey] = [.open, .closed, .merged, .inProgress, .completed, .blocked, .neutral]
        XCTAssertEqual(cases.count, 7)
    }

    // MARK: - AttachmentProvider exhaustiveness

    func testAllAttachmentProviderCases() {
        let cases: [AttachmentProvider] = [.github, .linear, .slack]
        XCTAssertEqual(cases.count, 3)
    }

    func testAttachmentProviderRawValues() {
        XCTAssertEqual(AttachmentProvider.github.rawValue, "github")
        XCTAssertEqual(AttachmentProvider.linear.rawValue, "linear")
        XCTAssertEqual(AttachmentProvider.slack.rawValue, "slack")
    }

    // MARK: - Hashable / Equatable

    func testAttachmentMetadata_Equatable() {
        let a = AttachmentMetadata(
            title: "T", statusLabel: "open", statusColorKey: .open,
            authorDisplayName: "u", createdAtMs: 1, externalURL: url
        )
        let b = AttachmentMetadata(
            title: "T", statusLabel: "open", statusColorKey: .open,
            authorDisplayName: "u", createdAtMs: 1, externalURL: url
        )
        XCTAssertEqual(a, b)
    }

    func testAttachmentMetadata_NotEqualOnTitleChange() {
        let a = AttachmentMetadata(
            title: "X", statusLabel: nil, statusColorKey: .neutral,
            authorDisplayName: "u", createdAtMs: 0, externalURL: url
        )
        let b = AttachmentMetadata(
            title: "Y", statusLabel: nil, statusColorKey: .neutral,
            authorDisplayName: "u", createdAtMs: 0, externalURL: url
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Codable round-trip

    func testAttachmentMetadata_CodableRoundTrip() throws {
        let original = AttachmentMetadata(
            title: "Fix memory leak",
            statusLabel: "merged",
            statusColorKey: .merged,
            authorDisplayName: "bob",
            createdAtMs: 1_716_500_000_123,
            externalURL: url
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AttachmentMetadata.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testStatusColorKey_CodableRoundTrip() throws {
        for key in [StatusColorKey.open, .closed, .merged, .inProgress, .completed, .blocked, .neutral] {
            let data = try JSONEncoder().encode(key)
            let decoded = try JSONDecoder().decode(StatusColorKey.self, from: data)
            XCTAssertEqual(decoded, key)
        }
    }
}
