//
//  LinearOAuthReauthorizing.swift
//  LeafCore
//
//  Track 5 / S6 T11 — narrow Sendable surface used by `LinearScopesReader`
//  to trigger an OAuth re-consent flow from the cross-post scope-missing
//  banner. Real implementation is `LinearOAuthService.connect()` in the
//  Leaf app target (which imports SwiftUI / AppKit + opens browser).
//  LeafCore can't depend on that target — hence the protocol seam.
//
//  Composition root wires the production `LinearOAuthService` (via a thin
//  adapter that conforms to this protocol) into the reader at T13.
//

import Foundation

/// Triggers the Linear OAuth re-consent flow. Errors are reported via the
/// implementer's own observable state machine, not by throwing — this
/// matches the `LinearOAuthService.connect()` semantics in the app target.
public protocol LinearOAuthReauthorizing: Sendable {
    func connect() async
}
