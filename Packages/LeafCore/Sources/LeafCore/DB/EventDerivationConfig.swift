import Foundation

/// Use-case rebuild Track A0 — instance-level wiring for write-time event
/// derivation (FTS indexing runs unconditionally; link derivation needs the
/// moat extractors + the workspace's Linear prefixes).
///
/// The Agent calls `Database.configureDerivation(_:)` once at startup; every
/// collector keeps calling the `write*` APIs without derivation parameters and
/// picks the config up implicitly. An explicit `knownLinearPrefixes:` /
/// `derivers:` argument at a call site still wins over the config (tests and
/// special-purpose callers can opt out with an empty set).
///
/// `linearPrefixes` is a closure, not a frozen set — prefixes come from
/// observed Linear payloads and grow over time (see `LinearPrefixSource`).
public struct EventDerivationConfig: Sendable {
  public let derivers: LinkDerivers
  public let linearPrefixes: @Sendable () -> Set<String>

  public init(
    derivers: LinkDerivers,
    linearPrefixes: @escaping @Sendable () -> Set<String>
  ) {
    self.derivers = derivers
    self.linearPrefixes = linearPrefixes
  }
}
