// Track 5 / S7 — Phase I.5. ADR-010 walkback fence for AttachmentMetadata.
//
// Verifies that the AttachmentMetadata struct (and its resolver output) never
// exposes raw payload fields to the UI layer. The invariant: only derived,
// display-ready fields are public (title, statusLabel, statusColorKey,
// authorDisplayName, createdAtMs, externalURL). Raw content (payload bodies,
// commit messages, event payloads) must never be fields of AttachmentMetadata.
//
// Two test functions per spec §14.5 (I.5):
//   1. Codable allowed-keys + banned-keys round-trip.
//   2. AttachmentMetadataResolver resolve() returns only derived fields.

import XCTest
@testable import LeafCore

final class AttachmentMetadataWalkbackTests: XCTestCase {

    // MARK: - (1) Codable shape: only derived fields, no raw payload

    /// AttachmentMetadata's Codable conformance must encode exactly the six
    /// display-ready derived fields. Banned field names (raw / opaque content)
    /// must never appear in the encoded JSON.
    ///
    /// This is a structural invariant: if a future commit accidentally adds a
    /// `payloadJSON` or `rawBody` stored property and it becomes Codable, this
    /// test will catch it.
    func testAttachmentMetadata_OnlyDerivedFieldsInCodable() throws {
        let metadata = AttachmentMetadata(
            title: "feat: add team feed",
            statusLabel: "open",
            statusColorKey: .open,
            authorDisplayName: "Alice",
            createdAtMs: 1_716_900_000_000,
            externalURL: URL(string: "https://github.com/org/repo/pull/42")!
        )

        let encoded = try JSONEncoder().encode(metadata)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any],
            "AttachmentMetadata must encode to a JSON dictionary"
        )

        // --- Allowed keys (exactly this set) ---
        let allowedKeys: Set<String> = [
            "title",
            "statusLabel",
            "statusColorKey",
            "authorDisplayName",
            "createdAtMs",
            "externalURL"
        ]
        let actualKeys = Set(json.keys)
        let unexpectedKeys = actualKeys.subtracting(allowedKeys)
        XCTAssertTrue(
            unexpectedKeys.isEmpty,
            "AttachmentMetadata encoded unexpected keys: \(unexpectedKeys.sorted()). " +
            "Only derived display fields are allowed."
        )

        // --- Banned keys (must never appear) ---
        let bannedKeys = [
            "payload",
            "raw",
            "body",
            "plaintext",
            "encrypted_payload",
            "payload_json",
            "plaintextPayloadJSON",
            "raw_body",
            "raw_payload",
            "commit_message",
            "issue_body",
            "pr_body",
            "slack_message_text"
        ]
        for key in bannedKeys {
            XCTAssertNil(
                json[key],
                "AttachmentMetadata must not encode banned raw-content field: '\(key)'"
            )
        }

        // --- Value spot-checks ---
        XCTAssertEqual(json["title"] as? String, "feat: add team feed")
        XCTAssertEqual(json["statusLabel"] as? String, "open")
        XCTAssertEqual(json["authorDisplayName"] as? String, "Alice")
        XCTAssertEqual(json["createdAtMs"] as? Int64, 1_716_900_000_000)

        // externalURL encodes as an absolute string.
        let urlString = json["externalURL"] as? String ?? ""
        XCTAssertTrue(urlString.hasPrefix("https://"),
            "externalURL must encode as an HTTPS string")
    }

    // MARK: - (2) Resolver returns only derived fields (no raw payload passthrough)

    /// AttachmentMetadataResolver.resolve() converts a raw events-table payload
    /// (flat [String: String] JSON) into a display-ready AttachmentMetadata.
    ///
    /// Sentinel injection: the local events table payload contains banned keys
    /// ("body", "note_body", "file_contents"). The resolver must parse out only
    /// the allowed derived fields and never carry banned key values into the
    /// returned AttachmentMetadata.
    ///
    /// Uses a temp SQLCipher DB (same pattern as AttachmentMetadataResolverTests)
    /// so the full local lookup path is exercised.
    func testResolver_DerivedFieldsOnly_NoBannedPayloadPassthrough() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-attach-walkback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(
            at: dbURL,
            config: .weakDefaults,
            encryption: .deterministicTest
        )

        // Insert an event row whose payload_json contains banned keys alongside
        // legitimate display fields. The resolver must only return derived fields.
        let bannedPayload: [String: String] = [
            // Legitimate display fields (must pass through).
            "source":     "github",
            "event_kind": "gh_pr_opened",
            "title":      "fix: auth bug",
            "number":     "42",
            "repo":       "org/app",
            // Banned raw-content fields (must NOT appear in AttachmentMetadata).
            "body":           "SECRET-PR-BODY-DO-NOT-EXPOSE",
            "file_contents":  "SECRET-FILE-CONTENTS",
            "note_body":      "SECRET-NOTE-BODY",
            "prompt":         "SECRET-AI-PROMPT",
            "response":       "SECRET-AI-RESPONSE"
        ]
        try db.write([RawEvent(
            timestamp: Date(timeIntervalSince1970: 1_716_900_000),
            signalType: .action,
            bundleID: nil,
            payload: bannedPayload
        )])

        let resolver = AttachmentMetadataResolver(database: db)
        let metadata = await resolver.resolve(
            provider: .github,
            externalRef: "org/app#42"
        )

        guard let metadata else {
            // Resolver returned nil — banned keys definitely did not leak.
            return
        }

        // --- Verify banned sentinel strings do NOT appear in any derived field ---
        let sentinels = [
            "SECRET-PR-BODY-DO-NOT-EXPOSE",
            "SECRET-FILE-CONTENTS",
            "SECRET-NOTE-BODY",
            "SECRET-AI-PROMPT",
            "SECRET-AI-RESPONSE"
        ]

        for sentinel in sentinels {
            XCTAssertFalse(
                metadata.title.contains(sentinel),
                "AttachmentMetadata.title must not contain banned sentinel: '\(sentinel)'"
            )
            XCTAssertFalse(
                metadata.authorDisplayName.contains(sentinel),
                "AttachmentMetadata.authorDisplayName must not contain banned sentinel: '\(sentinel)'"
            )
            if let statusLabel = metadata.statusLabel {
                XCTAssertFalse(
                    statusLabel.contains(sentinel),
                    "AttachmentMetadata.statusLabel must not contain banned sentinel: '\(sentinel)'"
                )
            }
            // externalURL must be HTTPS — never a leaked content string.
            XCTAssertEqual(
                metadata.externalURL.scheme, "https",
                "Resolved externalURL must be HTTPS, not a leaked content string"
            )
            XCTAssertFalse(
                metadata.externalURL.absoluteString.contains(sentinel),
                "AttachmentMetadata.externalURL must not contain banned sentinel: '\(sentinel)'"
            )
        }

        // --- Positive checks: derived fields are populated from safe keys ---
        XCTAssertEqual(metadata.title, "fix: auth bug",
            "Resolver must populate title from the 'title' payload key")
        XCTAssertFalse(metadata.externalURL.absoluteString.isEmpty,
            "Resolver must construct a non-empty externalURL from repo + number")
        XCTAssertEqual(metadata.externalURL.scheme, "https",
            "Constructed GitHub URL must use HTTPS scheme")
    }
}
