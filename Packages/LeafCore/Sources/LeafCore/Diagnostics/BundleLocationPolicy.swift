import Foundation

/// Location guard for SMAppService agent registration.
///
/// `SMAppService.register()` points the BTM parent record at the registering
/// bundle's path. A prod-bundle-id copy launched from a non-install location
/// (/tmp archive, DMG mount, Downloads, translocated path) re-points the
/// record away from /Applications/Leaf.app; launchd then resolves the agent
/// binary relative to that path and crash-loops with EX_CONFIG until the
/// record is repaired. Auto-register is therefore allowed only from a
/// canonical install location. Debug bundle ids register a separate label
/// (tech.gundem.leaf.debug.agent) and are exempt so the DerivedData dev flow
/// keeps working.
public enum BundleLocationPolicy {
  public static let overrideEnvKey = "LEAF_ALLOW_NONCANONICAL_REGISTER"

  /// Canonical = under /Applications/ or <home>/Applications/. Everything
  /// else (tmp, xcarchive, DerivedData, AppTranslocation, DMG volumes, ...)
  /// is non-canonical by exclusion — prefix match, not substring, so
  /// .xcarchive/Products/Applications/ does not qualify.
  public static func isCanonical(bundlePath: String, homePath: String) -> Bool {
    if bundlePath.hasPrefix("/Applications/") { return true }
    let home = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
    return bundlePath.hasPrefix(home + "/Applications/")
  }

  public static func shouldAutoRegister(
    bundleID: String,
    bundlePath: String,
    homePath: String,
    environment: [String: String]
  ) -> Bool {
    if bundleID.contains(".debug") { return true }
    if let override = environment[overrideEnvKey], !override.isEmpty { return true }
    return isCanonical(bundlePath: bundlePath, homePath: homePath)
  }
}
