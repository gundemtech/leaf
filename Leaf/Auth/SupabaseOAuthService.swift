//
//  SupabaseOAuthService.swift
//  Leaf
//
//  Phase 1 (account-login) — @Observable login controller for the gate's
//  LoginView. Two paths:
//   * email/password — the native app sends NO captcha token (global Supabase
//     CAPTCHA protection is OFF). Calls SupabaseClient.signInWithPassword then
//     ensureAuthenticatedAndPubkeyRegistered.
//   * OAuth (Google/GitHub) — opens the authorize URL in the user's DEFAULT
//     browser (NSWorkspace.open → Chrome/Safari/… with their already-signed-in
//     accounts) and catches the redirect on a local loopback HTTP server
//     (LoopbackCallbackListener, same pattern as the Linear/Slack/GitHub
//     integrations). PKCE throughout. The flow runs in a cancellable Task so
//     the LoginView "Cancel" affordance can abort it immediately instead of
//     waiting out the loopback timeout. We deliberately do NOT use
//     ASWebAuthenticationSession — it can only use Safari/WebKit, not the
//     user's real default browser.
//

import AppKit
import Foundation
import LeafCore
import SwiftUI

@MainActor
@Observable
final class SupabaseOAuthService {
  enum LoginState: Equatable {
    case idle
    case authorizing
    case exchangingToken
    case registeringDevice
    case authenticated
    /// User explicitly signed out. Distinct from `.idle` (the initial / never-
    /// touched value) so the gate's `.task(id: state)` re-fires even when the
    /// shell was reached via a persisted token (state stayed `.idle`). Renders
    /// the login form exactly like `.idle`.
    case signedOut
    /// Device-identity collision — this Mac's key is registered to a different
    /// account. The gate shows a reset-confirmation prompt (LoginView).
    case deviceConflict
    case error(message: String)
  }

  private(set) var state: LoginState = .idle

  private let client: SupabaseClient
  /// Called after a fully-successful login (session + pubkey registered) so
  /// LeafApp can register the launch agent and flip the gate. Set by LeafApp.
  var onAuthenticated: (() -> Void)?

  /// Called after a sign-out (session cleared) so LeafApp can unregister the
  /// launch agent and stop background capture. Set by LeafApp.
  var onSignedOut: (() -> Void)?

  /// OAuth redirect — a loopback URL so the flow can run in the user's DEFAULT
  /// browser. Fixed port (Linear uses 47823, Slack-relay 47824) so it can be
  /// added to Supabase's redirect allow-list. Must match the allow-list entry.
  private static let callbackPort: UInt16 = 47825
  static let redirectURI = "http://127.0.0.1:47825/callback"

  /// In-flight OAuth flow, so the UI "Cancel" can abort it.
  @ObservationIgnored private var oauthTask: Task<Void, Never>?

  init(client: SupabaseClient) {
    self.client = client
  }

  // MARK: - Email path

  /// Email/password login. The native app sends NO captcha token (global
  /// CAPTCHA is off). On success runs the device-registration sequence and
  /// flips the gate via onAuthenticated.
  func loginWithEmail(email: String, password: String) async {
    state = .exchangingToken
    do {
      _ = try await client.signInWithPassword(email: email, password: password)
      try await finishWithDeviceRegistration()
    } catch {
      setFailureState(error)
    }
  }

  // MARK: - OAuth path (default browser + loopback, cancellable)

  /// Start an OAuth flow. Cancellable via `cancelOAuth()`.
  func startOAuth(provider: OAuthProvider) {
    oauthTask?.cancel()
    oauthTask = Task { await self.runOAuth(provider: provider) }
  }

  /// Abort an in-flight OAuth flow (the LoginView "×"/Cancel) without waiting
  /// for the loopback timeout. Cancelling the task fires the listener's
  /// cancellation handler, which frees the loopback port; state returns to the
  /// form immediately.
  func cancelOAuth() {
    oauthTask?.cancel()
    oauthTask = nil
    state = .idle
  }

  // MARK: - Sign-out

  /// Sign out — clears the session (in-memory state + persisted refresh token
  /// via the client) and returns the app to the login gate. Cancels any
  /// in-flight OAuth flow first. `onSignedOut` lets LeafApp unregister the
  /// launch agent so background capture stops; RootView's `.task(id:)` observes
  /// the state flip back to `.idle` and re-arms LoginGateView.
  func signOut() async {
    oauthTask?.cancel()
    oauthTask = nil
    await client.signOut()
    state = .signedOut
    onSignedOut?()
  }

  private func runOAuth(provider: OAuthProvider) async {
    state = .authorizing
    let challenge = PKCE.makeChallenge()
    let authorizeURL = SupabaseEndpoint.oauthAuthorize(
      baseURL: client.baseURL,
      provider: provider.rawValue,
      redirectTo: Self.redirectURI,
      codeChallenge: challenge.challenge)
    do {
      // Open the user's DEFAULT browser (their real session / signed-in
      // accounts), then wait for the redirect on the loopback server.
      NSWorkspace.shared.open(authorizeURL)
      let callback = try await LoopbackCallbackListener.awaitCallback(
        port: Self.callbackPort,
        providerLabel: provider == .google ? "Google" : "GitHub")
      if Task.isCancelled { return }

      // Decision is a pure, unit-tested helper (OAuthCallback). Security rests
      // on PKCE — the code is bound to our code_verifier. No `state` check:
      // GoTrue brokers the flow and owns the provider-leg state itself.
      let outcome = OAuthCallback.evaluate(
        items: (callback.queryItems ?? []).map { ($0.name, $0.value) })
      switch outcome {
      case .cancelled:
        state = .idle  // user declined at the provider
        return
      case .providerError:
        state = .error(message: "Sign-in was cancelled or failed. Try again.")
        return
      case .missingCode:
        state = .error(message: "Login callback was missing an authorization code.")
        return
      case .proceed(let code):
        state = .exchangingToken
        _ = try await client.exchangeOAuthCode(
          code: code, codeVerifier: challenge.verifier, redirectURI: Self.redirectURI)
        if Task.isCancelled { return }
        try await finishWithDeviceRegistration()
      }
    } catch let loopback as LoopbackCallbackError {
      if Task.isCancelled { return }
      switch loopback {
      case .timeout:
        state = .idle  // user abandoned the browser tab
      default:
        state = .error(message: "Couldn't open the sign-in listener. Try again.")
      }
    } catch {
      if Task.isCancelled { return }
      setFailureState(error)
    }
  }

  enum OAuthProvider: String { case google, github }

  // MARK: - Internals

  private func finishWithDeviceRegistration() async throws {
    state = .registeringDevice
    _ = try await client.ensureAuthenticatedAndPubkeyRegistered()
    state = .authenticated
    onAuthenticated?()
  }

  // MARK: - Device-identity conflict recovery

  /// The device key is owned by another account (account switch on this Mac).
  /// Reset this device's identity and re-run registration so the CURRENT
  /// account claims a fresh key. Destructive — the previous account's local
  /// team data tied to the old key is orphaned (caller confirms first).
  func resetIdentityAndRetry() async {
    do {
      try IdentityService.deleteLocalIdentity()
      try await finishWithDeviceRegistration()
    } catch {
      setFailureState(error)
    }
  }

  /// Dismiss the device-conflict prompt back to the login form.
  func cancelDeviceConflict() {
    state = .idle
  }

  /// Route a login/registration failure: a device-key collision drives the
  /// reset-confirmation state; everything else shows an inline error.
  private func setFailureState(_ error: Error) {
    if let supa = error as? SupabaseError, supa == .deviceKeyOwnedByAnotherAccount {
      state = .deviceConflict
    } else {
      state = .error(message: friendlyMessage(error))
    }
  }

  private func friendlyMessage(_ error: Error) -> String {
    if let supa = error as? SupabaseError {
      switch supa {
      case .badRequest, .unauthorized: return "Wrong email or password — try again."
      case .identityClaimMissing, .pubkeyAlreadyRegistered, .deviceKeyOwnedByAnotherAccount:
        return "Couldn't register this device. Try again in a moment."
      case .transport: return "Network problem — check your connection and retry."
      default: return "Login failed (\(supa)). Try again."
      }
    }
    return error.localizedDescription
  }
}
