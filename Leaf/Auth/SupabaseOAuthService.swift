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
//     integrations). PKCE throughout. We deliberately do NOT use
//     ASWebAuthenticationSession — it can only use Safari/WebKit, not the
//     user's real default browser.
//  State machine mirrors LinearOAuthService.
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
    case error(message: String)
  }

  private(set) var state: LoginState = .idle

  private let client: SupabaseClient
  /// Called after a fully-successful login (session + pubkey registered) so
  /// LeafApp can register the launch agent and flip the gate. Set by LeafApp.
  var onAuthenticated: (() -> Void)?

  /// OAuth redirect — a loopback URL so the flow can run in the user's DEFAULT
  /// browser. Fixed port (Linear uses 47823, Slack-relay 47824) so it can be
  /// added to Supabase's redirect allow-list. Must match the allow-list entry.
  private static let callbackPort: UInt16 = 47825
  static let redirectURI = "http://127.0.0.1:47825/callback"

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
      state = .error(message: friendlyMessage(error))
    }
  }

  // MARK: - OAuth path (default browser + loopback)

  func loginWithOAuth(provider: OAuthProvider) async {
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

      if let oauthError = callback.queryItems?.first(where: { $0.name == "error" })?.value {
        // User denied at the provider, or the provider returned an error.
        state =
          oauthError == "access_denied"
          ? .idle
          : .error(message: "Sign-in was cancelled or failed. Try again.")
        return
      }
      guard let code = callback.queryItems?.first(where: { $0.name == "code" })?.value else {
        state = .error(message: "Login callback was missing an authorization code.")
        return
      }

      state = .exchangingToken
      _ = try await client.exchangeOAuthCode(
        code: code, codeVerifier: challenge.verifier, redirectURI: Self.redirectURI)
      try await finishWithDeviceRegistration()
    } catch let loopback as LoopbackCallbackError {
      // Timed out (user abandoned the browser tab) → soft return to the form;
      // bind/listener failures are surfaced.
      switch loopback {
      case .timeout:
        state = .idle
      default:
        state = .error(message: "Couldn't open the sign-in listener. Try again.")
      }
    } catch {
      state = .error(message: friendlyMessage(error))
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

  private func friendlyMessage(_ error: Error) -> String {
    if let supa = error as? SupabaseError {
      switch supa {
      case .badRequest, .unauthorized: return "Wrong email or password — try again."
      case .identityClaimMissing, .pubkeyAlreadyRegistered:
        return "Couldn't register this device. Try again in a moment."
      case .transport: return "Network problem — check your connection and retry."
      default: return "Login failed (\(supa)). Try again."
      }
    }
    return error.localizedDescription
  }
}
