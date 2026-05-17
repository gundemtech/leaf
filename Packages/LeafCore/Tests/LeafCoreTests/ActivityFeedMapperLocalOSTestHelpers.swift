// Shared helpers for ActivityFeedMapperLocalOS*Tests files.
// Split from ActivityFeedMapperLocalOSTests.swift for type_body_length / file_length.

import XCTest

@testable import LeafCore

// swiftlint:disable force_unwrapping
// Reason: test fixtures rely on force-unwrap for setup convenience —
// post-`try` JSON encoding where nil ⇒ broken test, not production semantic.

enum ActivityFeedMapperLocalOSTestSupport {
    static func payloadJSON(_ dict: [String: String]) -> String {
        // Test fixture; [String: String] always JSON-serializable.
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    static func map(
        kind: String,
        signalType: String = "context",
        bundleID: String? = nil,
        extras: [String: String] = [:]
    ) -> ActivityFeedEntry? {
        var payload = ["event_kind": kind]
        for (k, v) in extras { payload[k] = v }
        return ActivityFeedMapper.map(
            id: 1, timestampMs: 1_000, signalType: signalType,
            bundleID: bundleID, payloadJSON: payloadJSON(payload)
        )
    }
}
// swiftlint:enable force_unwrapping
