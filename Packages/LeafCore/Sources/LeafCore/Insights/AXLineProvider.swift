import Foundation

/// Track-9 T1 — AX line capture wrapper. Injectable for tests.
/// Production impl: ProdAXLineProvider (LeafCorePrivate moat).
public protocol AXLineProvider: Sendable {
    /// Returns 1-based line index of cursor selection in focused Xcode text area,
    /// or nil when: AX trust missing / focused element is not text area /
    /// Xcode pid stale / AX call throws.
    func readSelectedLine() -> Int?
}
