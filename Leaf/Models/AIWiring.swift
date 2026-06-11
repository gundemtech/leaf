//
//  AIWiring.swift
//  Leaf
//
//  AI-UI-1 — единая точка composition-root дефолтов для всех in-app AI-поверхностей
//  (HandoffDraftReader, HandoffAuditWriter, AskLeafReader). CR-2 boundary parity
//  с MCPServer.swift: под LEAF_PROD — prod moat + strict-mode; dev-билд получает
//  пустой substrate (fail-closed, без живого LLM egress). Тела перенесены из
//  HandoffDraftReader без изменений.
//

import Foundation
import LeafCore

#if LEAF_PROD
  import LeafCorePrivate
#endif

enum AIWiring {
  static func policy() -> LLMPolicy {
    #if LEAF_PROD
      return LLMPolicy(
        moat: prodLLMEgressMoat(), config: LLMPolicyConfig(strictMode: StrictModeReader.read()))
    #else
      return LLMPolicy(config: LLMPolicyConfig(strictMode: StrictModeReader.read()))
    #endif
  }

  static func summarizerMoat() -> AISummarizerMoat {
    #if LEAF_PROD
      return prodAISummarizerMoat(keyStore: FileAnthropicKeyStore())
    #else
      return .publicSubstrate
    #endif
  }

  /// AI-UI-4 — per-call BYOK-valve router for all in-app AI surfaces: key
  /// present → BYOK Anthropic; otherwise the team pool via the relay proxy
  /// (`prodAIProxySummarizerMoat`, bearer = the app's Supabase session). The
  /// session-backed token provider is constructed once by LeafApp (it owns
  /// the SupabaseClient) and threaded here.
  static func backendRouter(tokenProvider: any AIInferenceAuthTokenProvider) -> AIBackendRouter {
    #if LEAF_PROD
      return AIBackendRouter(
        keyStore: FileAnthropicKeyStore(),
        byok: prodAISummarizerMoat(keyStore: FileAnthropicKeyStore()),
        included: prodAIProxySummarizerMoat(tokenProvider: tokenProvider))
    #else
      return AIBackendRouter(
        keyStore: FileAnthropicKeyStore(), byok: .publicSubstrate, included: .publicSubstrate)
    #endif
  }

  static func modelGateMoat() -> ModelGateMoat {
    #if LEAF_PROD
      return prodModelGateMoat()
    #else
      return .publicSubstrate
    #endif
  }

  /// AI-UI-3 — dedicated handoff prompts. Prod text is moat quality
  /// (LeafCorePrivate); the public copy works (a prompt is not a secret
  /// dependency, so dev builds draft fine).
  static func handoffPromptMoat() -> HandoffPromptMoat {
    #if LEAF_PROD
      return prodHandoffPromptMoat()
    #else
      return .publicSubstrate
    #endif
  }

  static func databaseConfig() -> DatabaseConfig {
    #if LEAF_PROD
      return ProdConfigs.database
    #else
      return DatabaseConfig.weakDefaults
    #endif
  }

  static func databaseEncryption() -> EncryptionOptions? {
    #if LEAF_PROD
      return EncryptionOptions(
        keyProvider: .callback { @Sendable in try FileKeyStore.fetchOrCreate() },
        preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
        postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
      )
    #else
      return nil
    #endif
  }
}
