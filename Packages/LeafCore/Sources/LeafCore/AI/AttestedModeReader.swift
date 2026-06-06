import Foundation

/// P5 — reads the opt-in toggle that routes the AI-included path through the
/// verifiable (attested, open-weight) backend instead of the trust-based one.
///
/// **Off by default** — the attested path is experimental and stays at PoC
/// assurance until the full attestation chain (VCEK + Sigstore Rekor) and real
/// operator format land. Read from the shared cross-process suite `tech.gundem.leaf`
/// (same one `StrictModeReader`/`SystemObserversStore` use), so the MCP process sees
/// what the app writes. Default `false`; the read is reliable (no silent fail-open).
public enum AttestedModeReader {
  public static let key = "leaf.ai.attested_mode"

  public static func read(
    defaults: UserDefaults = SystemObserversStore.sharedDefaults
  ) -> Bool {
    defaults.bool(forKey: key)
  }
}
