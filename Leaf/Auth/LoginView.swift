//
//  LoginView.swift
//  Leaf
//
//  Phase 1 (account-login) — the gate sign-in screen, built on the Leaf design
//  system (tokens + LeafButton/LeafInput composites). Registration is web-only
//  (spec §2.2): this screen only signs in (email/password + Google/GitHub) and
//  links out to the site for register / password reset. Presented full-window
//  by RootView's gate (LoginGateView).
//

import AppKit
import SwiftUI

/// Public-facing site URLs (registration / password reset live on the web).
private enum LoginLinks {
  static let register = URL(string: "https://leaf.gundem.tech/signup")!
  static let forgotPassword = URL(string: "https://leaf.gundem.tech/signup?panel=forgot")!
}

struct LoginGateView: View {
  let service: SupabaseOAuthService
  var body: some View {
    LoginView(service: service)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(LeafColor.surface.canvas)
  }
}

struct LoginView: View {
  @Bindable var service: SupabaseOAuthService

  @State private var email = ""
  @State private var password = ""
  @State private var showPassword = false
  @State private var showDeviceConflict = false
  @FocusState private var pwFocused: Bool

  private var isBusy: Bool {
    switch service.state {
    case .authorizing, .exchangingToken, .registeringDevice: return true
    default: return false
    }
  }

  private var canSubmitEmail: Bool { !email.isEmpty && !password.isEmpty && !isBusy }

  private var errorMessage: String? {
    if case .error(let message) = service.state { return message }
    return nil
  }

  /// Waiting for the browser-based OAuth redirect — show the cancellable overlay.
  private var isAuthorizing: Bool { service.state == .authorizing }

  var body: some View {
    VStack {
      Spacer(minLength: LeafSpace.xl)
      card
      Spacer(minLength: LeafSpace.xl)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(LeafColor.surface.canvas)
    .overlay {
      if isAuthorizing { authorizingOverlay }
    }
    .onChange(of: service.state) { _, newState in
      if newState == .deviceConflict { showDeviceConflict = true }
    }
    .confirmationDialog(
      "This Mac is set up for another account",
      isPresented: $showDeviceConflict,
      titleVisibility: .visible
    ) {
      Button("Reset & Continue", role: .destructive) {
        Task { await service.resetIdentityAndRetry() }
      }
      Button("Cancel", role: .cancel) { service.cancelDeviceConflict() }
    } message: {
      Text(
        "This device's Leaf identity belongs to a different account. Reset it to sign in here — the previous account's local team data on this Mac will be removed."
      )
    }
  }

  private var card: some View {
    VStack(spacing: LeafSpace.lg) {
      brand
      fields
      signInButton
      if let errorMessage {
        Text(errorMessage)
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.status.danger)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      orDivider
      oauthButtons
      footer
    }
    .padding(LeafSpace.xxl)
    .frame(width: 380)
    .background(
      RoundedRectangle(cornerRadius: LeafRadius.xl, style: .continuous)
        .fill(LeafColor.surface.raised)
        .overlay(
          RoundedRectangle(cornerRadius: LeafRadius.xl, style: .continuous)
            .strokeBorder(LeafColor.border.subtle, lineWidth: 1)
        )
    )
  }

  private var brand: some View {
    VStack(spacing: LeafSpace.sm) {
      // The real Leaf product mark (same art as the app icon and the website),
      // sourced from Logo/ and bundled as a per-appearance imageset: white on
      // dark, ink on light. Pre-coloured, so render as-is — no template tint.
      Image(LeafIcons.brand.logoMark)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 48, height: 48)
      Text("Sign in to Leaf")
        .font(LeafType.title.medium)
        .foregroundStyle(LeafColor.text.primary)
      Text("Private memory for AI dev teams.")
        .font(LeafType.body.small)
        .foregroundStyle(LeafColor.text.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(.bottom, LeafSpace.xs)
  }

  private var fields: some View {
    VStack(spacing: LeafSpace.md) {
      LeafInput(text: $email, placeholder: "Email", size: .lg, prefixIcon: .system("envelope"))
        .textContentType(.username)
      passwordField
    }
  }

  /// Password field — mirrors LeafInput's visual tokens (LeafInput has no secure
  /// variant) and integrates the show/hide eye toggle on the trailing edge.
  private var passwordField: some View {
    let size = LeafInputTokens.Size.lg
    return HStack(spacing: LeafSpace.sm) {
      LeafIcon(systemName: "lock", size: .md, tint: LeafColor.text.tertiary)
      Group {
        if showPassword {
          TextField("Password", text: $password)
        } else {
          SecureField("Password", text: $password)
        }
      }
      .textFieldStyle(.plain)
      .font(LeafType.body.regular)
      .foregroundStyle(LeafColor.text.primary)
      .textContentType(.password)
      .focused($pwFocused)
      .onSubmit { if canSubmitEmail { submitEmail() } }
      Button {
        showPassword.toggle()
      } label: {
        Image(systemName: showPassword ? "eye.slash" : "eye")
          .foregroundStyle(LeafColor.text.tertiary)
      }
      .buttonStyle(.plain)
      .help(showPassword ? "Hide password" : "Show password")
    }
    .padding(.horizontal, size.horizontalPadding)
    .frame(height: size.height)
    .background(
      RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
        .fill(LeafColor.surface.canvas)
        .overlay(
          RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
            .strokeBorder(
              pwFocused ? LeafColor.border.focus : LeafColor.border.strong,
              lineWidth: pwFocused ? 2 : 1)
        )
    )
  }

  private var signInButton: some View {
    LeafButton(variant: .primary, size: .lg, isLoading: isBusy, action: submitEmail) {
      Text("Sign In").frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity)
    .opacity(canSubmitEmail || isBusy ? 1 : 0.55)
    .disabled(!canSubmitEmail)
  }

  private var orDivider: some View {
    HStack(spacing: LeafSpace.md) {
      Rectangle().fill(LeafColor.border.subtle).frame(height: 1)
      Text("or").font(LeafType.caption).foregroundStyle(LeafColor.text.tertiary)
      Rectangle().fill(LeafColor.border.subtle).frame(height: 1)
    }
  }

  private var oauthButtons: some View {
    VStack(spacing: LeafSpace.sm) {
      LeafButton(
        variant: .secondary, size: .lg,
        action: { service.startOAuth(provider: .google) }
      ) {
        oauthLabel("Continue with Google") {
          Image("leaf-brand-google")
            .renderingMode(.original)
            .resizable().aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
        }
      }
      .frame(maxWidth: .infinity)
      .disabled(isBusy)

      LeafButton(
        variant: .secondary, size: .lg,
        action: { service.startOAuth(provider: .github) }
      ) {
        oauthLabel("Continue with GitHub") {
          Image("leaf-brand-github")
            .renderingMode(.template)
            .resizable().aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
            .foregroundStyle(LeafColor.text.primary)
        }
      }
      .frame(maxWidth: .infinity)
      .disabled(isBusy)
    }
  }

  private func oauthLabel<Logo: View>(_ title: String, @ViewBuilder logo: () -> Logo) -> some View {
    HStack(spacing: LeafSpace.sm) {
      logo()
      Text(title)
    }
    .frame(maxWidth: .infinity)
  }

  /// Shown while the browser-based OAuth flow is in progress, so the user can
  /// cancel (× or Cancel) instead of waiting out the loopback timeout.
  private var authorizingOverlay: some View {
    ZStack {
      Color.black.opacity(0.25).ignoresSafeArea()
      VStack(spacing: LeafSpace.md) {
        HStack {
          Spacer()
          Button {
            service.cancelOAuth()
          } label: {
            Image(systemName: "xmark").foregroundStyle(LeafColor.text.tertiary)
          }
          .buttonStyle(.plain)
          .help("Cancel sign-in")
        }
        ProgressView()
        Text("Finish signing in in your browser.")
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.text.primary)
          .multilineTextAlignment(.center)
        Text("Pick your account, then come back to Leaf.")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.secondary)
          .multilineTextAlignment(.center)
        LeafButton("Cancel", variant: .secondary, size: .md) { service.cancelOAuth() }
          .padding(.top, LeafSpace.xs)
      }
      .padding(LeafSpace.xl)
      .frame(width: 300)
      .background(
        RoundedRectangle(cornerRadius: LeafRadius.xl, style: .continuous)
          .fill(LeafColor.surface.raised)
          .overlay(
            RoundedRectangle(cornerRadius: LeafRadius.xl, style: .continuous)
              .strokeBorder(LeafColor.border.subtle, lineWidth: 1)
          )
      )
    }
  }

  private var footer: some View {
    HStack(spacing: LeafSpace.lg) {
      Button("Forgot password?") { NSWorkspace.shared.open(LoginLinks.forgotPassword) }
        .buttonStyle(.plain)
        .font(LeafType.body.small)
        .foregroundStyle(LeafColor.accent.primary)
      Button("No account? Register →") { NSWorkspace.shared.open(LoginLinks.register) }
        .buttonStyle(.plain)
        .font(LeafType.body.small)
        .foregroundStyle(LeafColor.accent.primary)
    }
    .padding(.top, LeafSpace.xs)
  }

  private func submitEmail() {
    Task { await service.loginWithEmail(email: email, password: password) }
  }
}
