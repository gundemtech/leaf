import Foundation

/// Phase 4.7.B (B-8) — pure-function namespace для классификации Linear
/// attachment URLs. Используется в `ProdLinearGraphQLProvider` parser'е чтобы
/// derive cross-provider links (GitHub PR / Slack permalink) из
/// `Issue.attachments(first: 10)` block'а.
///
/// **ADR-010 invariant:** парсер работает на URL string, который Linear отдал
/// как metadata об attachment'е. URL — public-safe (привязан к share-list через
/// upstream Share Controls; whitepaper Section 6 действия "Action" разрешают
/// URLs / file identifiers as metadata, а bodies / titles — нет). Парсер
/// возвращает только структурные части (repo + PR number, channel ID + ts);
/// никаких body / page title / metadata JSON не читает (provider их и не
/// запрашивает в GraphQL).
///
/// **Supported patterns:**
/// - GitHub PR: `https://github.com/<owner>/<repo>/pull/<num>`
///   → `(repo: "owner/repo", prNumber: Int)`. Trailing slash / query string OK.
///   - Issues URLs (`/issues/<num>`) **отвергаются** — другая семантика.
///   - `api.github.com` — отвергаются (не human-readable PR URL).
/// - Slack permalink: `https://<workspace>.slack.com/archives/<channel_id>/p<ts>`
///   → `(channelID: "C123", ts: "1234567890.123456")`. Slack permalink convention:
///   `p1234567890123456` (16 digit suffix) → `1234567890.123456` (insert `.`
///   после первых 10 chars). Если ts короче 16 chars, fallback к raw — defensive.
public enum LinearAttachmentParser {

    /// GitHub PR URL → (repo, prNumber). Force-try OK — pattern compile-time constant.
    private static let githubPRPattern: NSRegularExpression = {
        // ^https://github\.com/(<owner>)/(<repo>)/pull/(<num>)
        // Trailing chars (slash, query string, fragment) разрешены за счёт отсутствия
        // anchor `$`; capture groups строго берут owner / repo / num.
        try! NSRegularExpression(
            pattern: #"^https://github\.com/([^/?#]+)/([^/?#]+)/pull/(\d+)"#,
            options: []
        )
    }()

    /// Slack permalink → (channelID, ts).
    private static let slackPermalinkPattern: NSRegularExpression = {
        // ^https://<workspace>.slack.com/archives/<channel>/p<digits>
        // Channel ID — alphanumeric (Slack uses `C12345...` / `D...` / `G...`).
        // ts — digits (>=10 чтобы UNIX seconds part разумно валидным был).
        try! NSRegularExpression(
            pattern: #"^https://[^./?#]+\.slack\.com/archives/([A-Z0-9]+)/p(\d{10,})"#,
            options: []
        )
    }()

    /// Tries to match URL as GitHub PR. Returns `(repo, prNumber)` on success, `nil` иначе.
    /// Repo формируется как `"<owner>/<repo>"` (compose'ится parser'ом для downstream
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

    /// Tries to match URL as Slack permalink. Returns `(channelID, ts)` on success, `nil` иначе.
    /// `ts` decoded from `pXXXXXXXXXX...` form: первые 10 цифр = UNIX seconds,
    /// остальные = microseconds part (типично 6 chars). Insert `.` после 10 chars
    /// чтобы получить native Slack ts format `<seconds>.<micros>` (matches
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
        // Slack convention: первые 10 chars = seconds, rest = microseconds.
        // If raw < 10 chars (very unlikely — pattern already requires >= 10),
        // вернём raw без точки — graceful degrade.
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
