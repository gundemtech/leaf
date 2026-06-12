import Foundation

/// Use-case rebuild Track B0 — "is this bundle a place where work happens".
///
/// `currentWork` used to project the literal latest attention event, so the
/// NOW hero / `leaf_current_work` / the handoff snapshot reported Telegram as
/// the current app and a messenger window title as the current file (live
/// finding 2026-06-11). The heuristic is an ALLOWLIST and fails closed:
/// no dev-relevant app in the recent window → nil, never a messenger.
///
/// Injectable so prod/Settings can later supply a richer closure (e.g. the
/// user's share_apps whitelist) without an API change.
public struct WorkAppHeuristic: Sendable {
  public let isDevRelevant: @Sendable (_ bundleID: String) -> Bool

  public init(isDevRelevant: @escaping @Sendable (String) -> Bool) {
    self.isDevRelevant = isDevRelevant
  }

  /// Prefix allowlist of dev tools: IDEs, editors, terminals, dev utilities.
  /// Deliberately excludes communication apps (Slack/Telegram/Discord) — they
  /// are work-adjacent but never "the thing being built", which is what the
  /// NOW hero and the handoff card describe.
  public static let standard = WorkAppHeuristic { bundleID in
    let prefixes = [
      "com.apple.dt.Xcode",
      "com.apple.Terminal",
      "com.googlecode.iterm2",
      "dev.warp.",
      "com.microsoft.VSCode",
      "com.visualstudio.code",
      "com.vscodium",
      "com.todesktop.",          // Cursor
      "com.exafunction.windsurf",
      "com.jetbrains.",
      "com.google.android.studio",
      "com.sublimetext.",
      "com.github.",             // GitHub Desktop
      "com.git-tower.",
      "com.fournova.",           // Tower
      "co.zeit.hyper",
      "net.kovidgoyal.kitty",
      "com.mitchellh.ghostty",
      "org.alacritty",
      "com.anthropic.claude-code",
      "com.figma.Desktop",
      "com.postmanlabs.mac",
      "com.kapeli.dashdoc",
    ]
    return prefixes.contains { bundleID.hasPrefix($0) }
  }
}
