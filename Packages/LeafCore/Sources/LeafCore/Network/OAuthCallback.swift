//
//  OAuthCallback.swift
//  LeafCore
//
//  Phase 1 (account-login) — pure decision for the loopback OAuth redirect.
//  Extracted from SupabaseOAuthService.runOAuth so the error / code branching
//  is unit-testable without NSWorkspace + the loopback server.
//

import Foundation

/// What the loopback OAuth callback resolved to.
public enum OAuthCallbackOutcome: Equatable, Sendable {
  /// Provider returned `error=access_denied` — user declined; return to the form.
  case cancelled
  /// Provider returned some other `error=...` — surface a generic failure.
  case providerError
  /// No `error` but no `code` — malformed callback.
  case missingCode
  /// Good to exchange — carries the authorization code.
  case proceed(code: String)
}

public enum OAuthCallback {
  /// Pure decision for the loopback OAuth callback query items.
  ///
  /// Security rests on PKCE: the authorization code is bound to a
  /// `code_verifier` that never leaves this process, so an injected code can't
  /// be exchanged. We deliberately do NOT validate an OAuth `state` — Supabase
  /// GoTrue is a broker that owns the provider-leg state itself; passing a
  /// caller-supplied `state` to `/authorize` breaks GoTrue with
  /// `bad_oauth_state`. This mirrors supabase-js, which relies on PKCE alone.
  public static func evaluate(items: [(name: String, value: String?)]) -> OAuthCallbackOutcome {
    func first(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

    if let oauthError = first("error") {
      return oauthError == "access_denied" ? .cancelled : .providerError
    }
    guard let code = first("code") else { return .missingCode }
    return .proceed(code: code)
  }
}
