import Foundation

/// Phase 4.7.B (B-8) — pure-function namespace for classifying Linear
/// attachment URLs. Used in the `ProdLinearGraphQLProvider` parser to
/// derive cross-provider links (GitHub PR / Slack permalink) from the
/// `Issue.attachments(first: 10)` block.
///
/// **ADR-010 invariant:** the parser works on the URL string that Linear returned
/// as metadata about the attachment. The URL is public-safe (tied to the share-list via
/// upstream Share Controls; whitepaper Section 6 "Action" events allow
/// URLs / file identifiers as metadata, but bodies / titles — no). The parser
/// returns only structural parts (repo + PR number, channel ID + ts);
/// it reads no body / page title / metadata JSON (the provider doesn't even
/// request those in GraphQL).
///
/// **Supported patterns:**
/// - GitHub PR: `https://github.com/<owner>/<repo>/pull/<num>`
///   → `(repo: "owner/repo", prNumber: Int)`. Trailing slash / query string OK.
///   - Issues URLs (`/issues/<num>`) are **rejected** — different semantics.
///   - `api.github.com` — rejected (not a human-readable PR URL).
/// - Slack permalink: `https://<workspace>.slack.com/archives/<channel_id>/p<ts>`
///   → `(channelID: "C123", ts: "1234567890.123456")`. Slack permalink convention:
///   `p1234567890123456` (16 digit suffix) → `1234567890.123456` (insert `.`
///   after the first 10 chars). If ts is shorter than 16 chars, fall back to raw — defensive.
public enum LinearAttachmentParser {

    /// GitHub PR URL → (repo, prNumber). Force-try OK — pattern compile-time constant.
    private static let githubPRPattern: NSRegularExpression = {
        // ^https://github\.com/(<owner>)/(<repo>)/pull/(<num>)
        // Trailing chars (slash, query string, fragment) are allowed thanks to the missing
        // `$` anchor; capture groups strictly take owner / repo / num.
        try! NSRegularExpression(
            pattern: #"^https://github\.com/([^/?#]+)/([^/?#]+)/pull/(\d+)"#,
            options: []
        )
    }()

    /// Slack permalink → (channelID, ts).
    private static let slackPermalinkPattern: NSRegularExpression = {
        // ^https://<workspace>.slack.com/archives/<channel>/p<digits>
        // Channel ID — alphanumeric (Slack uses `C12345...` / `D...` / `G...`).
        // ts — digits (>=10 so the UNIX seconds part is reasonably valid).
        try! NSRegularExpression(
            pattern: #"^https://[^./?#]+\.slack\.com/archives/([A-Z0-9]+)/p(\d{10,})"#,
            options: []
        )
    }()

    /// Tries to match URL as GitHub PR. Returns `(repo, prNumber)` on success, `nil` otherwise.
    /// Repo is formed as `"<owner>/<repo>"` (composed by the parser for downstream
    /// presence_state.linear top-repo aggregation).
    public static func parseGitHubPR(_ url: String) -> (repo: String, prNumber: Int)? {
        guard !url.isEmpty else { return nil }
        let range = NSRange(url.startIndex..., in: url)
        guard let match = githubPRPattern.firstMatch(in: url, options: [], range: range),
              match.numberOfRanges == 4,
              let ownerR = Range(match.range(at: 1), in: url),
              let repoR = Range(match.range(at: 2), in: url),
              let numR = Range(match.range(at: 3), in: url),
              let num = Int(url[numR])
        else { return nil }
        let owner = String(url[ownerR])
        let repo = String(url[repoR])
        return (repo: "\(owner)/\(repo)", prNumber: num)
    }

    /// Tries to match URL as Slack permalink. Returns `(channelID, ts)` on success, `nil` otherwise.
    /// `ts` decoded from `pXXXXXXXXXX...` form: first 10 digits = UNIX seconds,
    /// the rest = microseconds part (typically 6 chars). Insert `.` after 10 chars
    /// to get the native Slack ts format `<seconds>.<micros>` (matches the
    /// `Conversation.message.ts` field).
    public static func parseSlackPermalink(_ url: String) -> (channelID: String, ts: String)? {
        guard !url.isEmpty else { return nil }
        let range = NSRange(url.startIndex..., in: url)
        guard let match = slackPermalinkPattern.firstMatch(in: url, options: [], range: range),
              match.numberOfRanges == 3,
              let channelR = Range(match.range(at: 1), in: url),
              let tsR = Range(match.range(at: 2), in: url)
        else { return nil }
        let channelID = String(url[channelR])
        let rawTs = String(url[tsR])
        // Slack convention: first 10 chars = seconds, rest = microseconds.
        // If raw < 10 chars (very unlikely — pattern already requires >= 10),
        // return raw without the dot — graceful degrade.
        let ts: String = {
            if rawTs.count > 10 {
                let cut = rawTs.index(rawTs.startIndex, offsetBy: 10)
                return "\(rawTs[..<cut]).\(rawTs[cut...])"
            }
            return rawTs
        }()
        return (channelID: channelID, ts: ts)
    }
}
