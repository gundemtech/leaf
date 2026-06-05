import Foundation

/// Injection seam for the bucket-1 "never to cloud" personal-app list
/// (mirrors `DetectorMoat`). The real personal-app bundle-ID set is the moat:
/// it is supplied from `LeafCorePrivate` (`prodLLMEgressMoat()`), gitignored
/// from the public repo.
///
/// The PUBLIC `publicSubstrate` carries **no** personal-app bundle IDs:
/// `pre-push-leaf` forbids Share-Controls preset bundle IDs in the public
/// `leaf` repo, and the substrate is only ever used in CI / tests where there
/// is no live LLM egress. Production always injects the real list, so an empty
/// public default cannot under-redact a real user. Tests inject their own
/// placeholder set (e.g. `["com.test.personal"]`).
public struct LLMEgressMoat: Sendable {
  /// Bucket-1: events from these bundle IDs are dropped entirely on the LLM
  /// path (neither body nor app+time leaves — §4.1).
  public let neverToCloudBundleIDs: Set<String>

  public init(neverToCloudBundleIDs: Set<String>) {
    self.neverToCloudBundleIDs = neverToCloudBundleIDs
  }

  /// CI / public-substrate default. Empty by design (see type doc).
  public static let publicSubstrate = LLMEgressMoat(neverToCloudBundleIDs: [])
}
