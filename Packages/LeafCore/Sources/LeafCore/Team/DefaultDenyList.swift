import Foundation

/// Phase Track-5 S5 — hardcoded default deny-list per Track 5 contract §6 +
/// §11.2. Applied **before** encryption ("no partial events"); a match drops
/// the entire event regardless of `share_rules.enabled`.
///
/// Defense in depth:
/// 1. event.kind starts with `ai_` (currently no event_kinds match — ADR-010
///    prohibits AI prompt/response content at the hook level; this is
///    belt-and-braces.)
/// 2. any string payload field contains a banned path fragment:
///    `.env`, `.git/config`, `.aws/credentials`, `.ssh/`
/// 3. payload field `file_size` (string-encoded int) > 100 MB.
///
/// Surface-area note: payload fields arrive here as `[String: String]` (event
/// row payload pre-projection). `TeamEventPayloadBuilder.build` is the **only**
/// production code path that constructs `TeamEventPayload.fields` from
/// `event.payload`; the denylist must run before the builder so that filtered
/// fields aren't even projected.
public struct DefaultDenyList: Sendable {

    public init() {}

    /// Returns true if event should be dropped before encryption.
    ///
    /// I3 Stage 6 review fix — fragment matching restricted to "pathy" keys
    /// (file_path, file_paths_json, branch, target_ref, ref_name, repo_full_name).
    /// Previously scanned every payload value, which false-matched legitimate
    /// commit messages like `"chore: improve .env handling"`. The pathy-key
    /// allowlist is the only way collectors emit actual filesystem paths in
    /// Layer A/B today; if a future collector emits paths under a different
    /// key, add it here AND add a regression test.
    public func matches(eventKind: String, payload: [String: String]) -> Bool {
        if Self.isAIContentKind(eventKind) {
            return true
        }
        for key in Self.pathyKeys {
            guard let value = payload[key] else { continue }
            for fragment in Self.bannedPathFragments where value.contains(fragment) {
                return true
            }
        }
        if let sizeStr = payload[Self.fileSizeKey],
           let size = Int(sizeStr),
           size > Self.maxFileSize {
            return true
        }
        return false
    }

    // MARK: - Internals

    private static let fileSizeKey = "file_size"

    /// Whitelisted "pathy" payload keys — only these are scanned for banned
    /// path fragments. Adding a new collector that emits paths under a
    /// different key requires a deliberate update here AND a regression test.
    static let pathyKeys: Set<String> = [
        "file_path",
        "file_paths_json",
        "branch",
        "target_ref",
        "ref_name",
        "repo_full_name",
    ]

    /// Banned path fragments — match anywhere in a payload string value.
    /// Order: dot-prefixed first (faster reject for hot path).
    static let bannedPathFragments: [String] = [
        ".env",
        ".git/config",
        ".aws/credentials",
        ".ssh/"
    ]

    /// 100 MB per contract §6.
    static let maxFileSize = 100_000_000

    /// event_kind classifier — anything matching is treated as AI content
    /// and dropped before encryption. Currently empty (ADR-010 prevents AI
    /// content from reaching the events table at all) but the prefix guard
    /// stays as a defensive layer.
    static func isAIContentKind(_ kind: String) -> Bool {
        kind.hasPrefix("ai_")
    }
}
