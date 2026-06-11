//
//  AIBackendRouterEnvironmentKey.swift
//  Leaf
//
//  AI-UI-4 — SwiftUI EnvironmentKey for the per-call BYOK-valve router.
//  AIBackendRouter is a plain Sendable struct (not @Observable), so the
//  `.environment(value:)` overload doesn't apply; this custom key threads it
//  from LeafApp's composition root to the sheets that build their readers
//  locally (EscalationSheet, InboundHandoffContextSheet).
//
//  Default is the substrate router (both legs NoOp — fail-closed, zero live
//  LLM egress) so previews and tests render without wiring.
//

import LeafCore
import SwiftUI

private struct AIBackendRouterEnvironmentKey: EnvironmentKey {
  static let defaultValue = AIBackendRouter(
    keyStore: FileAnthropicKeyStore(), byok: .publicSubstrate, included: .publicSubstrate)
}

extension EnvironmentValues {
  var aiBackendRouter: AIBackendRouter {
    get { self[AIBackendRouterEnvironmentKey.self] }
    set { self[AIBackendRouterEnvironmentKey.self] = newValue }
  }
}
