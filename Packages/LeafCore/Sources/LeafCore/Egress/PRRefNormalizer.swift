import Foundation

/// Track AI Coworker P3 — PUBLIC egress-hygiene transform. Converts a leaky
/// canonical GitHub PR reference `owner/repo/pull/42` (the shape `event_links`
/// stores for `target_kind='github_pr'`, produced by the moat `PRURLParser`)
/// into the bare, de-identified `#42`. Strips `owner/repo` so a customer /
/// codename org-or-repo slug never reaches the cloud LLM via an allow-listed
/// `target_ref`.
///
/// PUBLIC (not moat): this is an auditable privacy guarantee, not a detection
/// secret. Total + pure. Precision tradeoff (accepted): bare `#42` conflates
/// PRs across repos, but the LLM matches it to the user's OWN `number=42`
/// self-authored events that ride alongside — within one user's corpus this is
/// adequate, and the alternative (shipping `owner/repo`) leaks identity.
public enum PRRefNormalizer {
  /// `owner/repo/pull/42` → `#42`. Returns nil if `ref` is not a canonical
  /// 4-segment `*/*/pull/<digits>` shape — fail-closed: the caller drops the
  /// row rather than ship an unrecognized `github_pr` target_ref.
  public static func bareNumber(fromCanonicalPRRef ref: String) -> String? {
    let parts = ref.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[2] == "pull" else { return nil }
    let num = parts[3]
    guard !num.isEmpty, num.allSatisfy(\.isNumber) else { return nil }
    return "#\(num)"
  }
}
