import Foundation

/// P1 — reads the §4.3 "строгий режим" toggle for the AI Q&A self-authored
/// boundary. When ON, the user's own authored labels (commit/PR/branch titles)
/// are withheld from the default path (they move to escalation).
///
/// Read from the shared cross-process UserDefaults suite `tech.gundem.leaf`
/// (the same one `SystemObserversStore`/`LocalAppsStore` + the OAuth token
/// refreshers use) so the read-only MCP process reliably sees the value the app
/// writes — both `Leaf.app` and `LeafMCP` are unsandboxed, so the suite resolves
/// to the same `~/Library/Preferences/tech.gundem.leaf.plist`. Default `false`
/// (§4.3 — self-authored labels go by default; the read is reliable, so there is
/// no silent fail-open).
public enum StrictModeReader {
  public static let key = "leaf.ai.strict_mode"

  public static func read(
    defaults: UserDefaults = SystemObserversStore.sharedDefaults
  ) -> Bool {
    defaults.bool(forKey: key)
  }
}
