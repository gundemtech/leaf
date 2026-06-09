//
//  LoginView.swift
//  Leaf
//
//  Phase 1 (account-login) — the gate screen. Registration is web-only
//  (spec §2.2) so there is NO sign-up form here; only login + a "register on
//  the site" link. Email path: the user types email + password and hits Sign
//  In (the native app sends NO captcha token — global Supabase CAPTCHA is off).
//  OAuth path: Google/GitHub buttons. LoginGateView is the wrapper the RootView
//  gate presents.
//

import AppKit
import SwiftUI

/// Public-facing site URLs (registration / password reset live on the web).
private enum LoginLinks {
  static let register = URL(string: "https://leaf.gundem.tech/signup")!
  static let forgotPassword = URL(string: "https://leaf.gundem.tech/signup#reset")!
}

struct LoginGateView: View {
  let service: SupabaseOAuthService
  var body: some View {
    LoginView(service: service)
      .frame(minWidth: 420, minHeight: 520)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct LoginView: View {
  @Bindable var service: SupabaseOAuthService

  @State private var email = ""
  @State private var password = ""

  private var isBusy: Bool {
    switch service.state {
    case .authorizing, .exchangingToken, .registeringDevice: return true
    default: return false
    }
  }

  private var canSubmitEmail: Bool {
    !email.isEmpty && !password.isEmpty && !isBusy
  }

  var body: some View {
    VStack(spacing: 20) {
      Text("Sign in to Leaf").font(.title2).bold()

      VStack(spacing: 10) {
        TextField("Email", text: $email)
          .textFieldStyle(.roundedBorder)
          .textContentType(.username)
        SecureField("Password", text: $password)
          .textFieldStyle(.roundedBorder)
          .textContentType(.password)
          .onSubmit { if canSubmitEmail { submitEmail() } }
      }

      Button(action: submitEmail) {
        Text("Sign In").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canSubmitEmail)

      HStack {
        VStack { Divider() }
        Text("or").font(.caption).foregroundStyle(.secondary)
        VStack { Divider() }
      }

      VStack(spacing: 10) {
        Button {
          Task { await service.loginWithOAuth(provider: .google) }
        } label: {
          Label("Continue with Google", systemImage: "globe").frame(maxWidth: .infinity)
        }
        .disabled(isBusy)
        Button {
          Task { await service.loginWithOAuth(provider: .github) }
        } label: {
          Label("Continue with GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            .frame(maxWidth: .infinity)
        }
        .disabled(isBusy)
      }

      if case .error(let message) = service.state {
        Text(message).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
      }
      if isBusy { ProgressView() }

      HStack(spacing: 16) {
        Button("Forgot password?") { NSWorkspace.shared.open(LoginLinks.forgotPassword) }
          .buttonStyle(.link)
        Button("No account? Register on the site →") {
          NSWorkspace.shared.open(LoginLinks.register)
        }
        .buttonStyle(.link)
      }
      .font(.footnote)
    }
    .padding(32)
  }

  private func submitEmail() {
    Task { await service.loginWithEmail(email: email, password: password) }
  }
}
