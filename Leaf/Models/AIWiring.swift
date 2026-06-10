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
