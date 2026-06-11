//
//  AccountProfileFormat.swift
//  LeafCore
//
//  Pure display helpers for the Profile account surface. No I/O — unit-tested.
//

import Foundation

public enum AccountProfileFormat {
  /// Human label for an auth provider id. Unknown providers are capitalized.
  public static func providerLabel(_ raw: String?) -> String {
    switch (raw ?? "email").lowercased() {
    case "email": return "Email"
    case "google": return "Google"
    case "github": return "GitHub"
    case let other where other.isEmpty: return "Email"
    case let other: return other.prefix(1).uppercased() + other.dropFirst()
    }
  }

  /// Account display name: full_name if present, else the email local-part.
  /// Returns nil when neither is available (caller adds workspace/"Local user"
  /// fallback).
  public static func accountName(_ profile: SupabaseUserProfile) -> String? {
    if let n = profile.fullName, !n.isEmpty { return n }
    if let email = profile.email, let at = email.firstIndex(of: "@") {
      let local = String(email[..<at])
      if !local.isEmpty { return local }
    }
    return nil
  }

  /// Format a GoTrue ISO-8601 created_at string as "d MMM yyyy" (e.g.
  /// "10 Jun 2024"), matching the web dashboard. Handles fractional and
  /// non-fractional seconds. nil for missing/unparseable input.
  public static func memberSince(isoString: String?) -> String? {
    guard let s = isoString, !s.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    guard let date = fractional.date(from: s) ?? plain.date(from: s) else { return nil }
    let out = DateFormatter()
    out.locale = Locale(identifier: "en_US_POSIX")
    out.timeZone = TimeZone(identifier: "UTC")
    out.dateFormat = "d MMM yyyy"
    return out.string(from: date)
  }
}
