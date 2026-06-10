//
//  SupabaseOAuthService.swift
//  Leaf
//
//  Phase 1 (account-login) — @Observable login controller for the gate's
//  LoginView. Two paths:
//   * email/password — the native app sends NO captcha token (global Supabase
//     CAPTCHA protection is OFF). Calls SupabaseClient.signInWithPassword then
//     ensureAuthenticatedAndPubkeyRegistered.
//   * OAuth (Google/GitHub) — PKCE + ASWebAuthenticationSession with the
//     fixed custom-scheme callback leaf://auth/callback (Supabase redirect
//     allow-list requires an exact URL; ephemeral loopback ports don't fit).
//     PKCE.swift is reused. InviteURLHandler is NOT touched — ASWebAuth
//     delivers the redirect to its own completion handler.
//  State machine mirrors LinearOAuthService.
//

import AuthenticationServices
import Foundation
import LeafCore
import SwiftUI
import os

private let supabaseOAuthLogger = Logger(
  subsystem: "tech.gundem.leaf.app", category: "supabase-oauth")

@MainActor
@Observable
final class SupabaseOAuthService: NSObject {
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

  /// Fixed OAuth callback — must be on Supabase's redirect allow-list.
  static let redirectURI = "leaf://auth/callback"
  private static let callbackScheme = "leaf"

  /// Retained for the duration of one OAuth flow.
  private var webAuthSession: ASWebAuthenticationSession?

  init(client: SupabaseClient) {
    self.client = client
    super.init()
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

  // MARK: - OAuth path

  func loginWithOAuth(provider: OAuthProvider) async {
    state = .authorizing
    let challenge = PKCE.makeChallenge()
    let authorizeURL = SupabaseEndpoint.oauthAuthorize(
      baseURL: client.baseURL,
      provider: provider.rawValue,
      redirectTo: Self.redirectURI,
      codeChallenge: challenge.challenge)
    do {
      let callbackURL = try await startWebAuth(authorizeURL: authorizeURL)
      guard let code = Self.extractCode(from: callbackURL) else {
        state = .error(message: "Login callback was missing an authorization code.")
        return
      }
      state = .exchangingToken
      _ = try await client.exchangeOAuthCode(
        code: code, codeVerifier: challenge.verifier, redirectURI: Self.redirectURI)
      try await finishWithDeviceRegistration()
    } catch let asError as ASWebAuthenticationSessionError where asError.code == .canceledLogin {
      state = .idle  // user dismissed the sheet — silent return to the form
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

  private func startWebAuth(authorizeURL: URL) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(
        url: authorizeURL, callbackURLScheme: Self.callbackScheme
      ) { callbackURL, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let callbackURL {
          continuation.resume(returning: callbackURL)
        } else {
          continuation.resume(throwing: URLError(.badServerResponse))
        }
      }
      session.presentationContextProvider = self
      // Share Safari's cookies (NOT ephemeral) so the user's already-signed-in
      // Google/GitHub accounts appear for one-tap selection instead of a cold
      // login each time. macOS shows a one-time "wants to sign in" consent.
      session.prefersEphemeralWebBrowserSession = false
      self.webAuthSession = session
      if !session.start() {
        continuation.resume(throwing: URLError(.cannotConnectToHost))
      }
    }
  }

  private static func extractCode(from url: URL) -> String? {
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    return comps?.queryItems?.first(where: { $0.name == "code" })?.value
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

// MARK: - ASWebAuthenticationPresentationContextProviding

extension SupabaseOAuthService: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? ASPresentationAnchor()
  }
}
