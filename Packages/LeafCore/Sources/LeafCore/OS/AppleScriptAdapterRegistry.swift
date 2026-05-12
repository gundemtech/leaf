import Foundation

/// Phase Track-4 S2 — list of `AppleScriptAdapter` instances available to the
/// orchestrator. Public substrate ships `EmptyAppleScriptAdapterRegistry`;
/// production wires `ProdAppleScriptAdapterRegistry` (LeafCorePrivate, moat)
/// via `#if LEAF_PROD` in `Agent.main()`.
public protocol AppleScriptAdapterRegistry: Sendable {
    var adapters: [any AppleScriptAdapter] { get }
}

public struct EmptyAppleScriptAdapterRegistry: AppleScriptAdapterRegistry {
    public init() {}
    public var adapters: [any AppleScriptAdapter] { [] }
}
