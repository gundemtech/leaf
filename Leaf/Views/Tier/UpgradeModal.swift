//
//  UpgradeModal.swift
//  Track 5 / S8 / T3 — placeholder upgrade modal shown when a free-tier user
//  hits a gated capability (createWorkspace / sendDM / acceptInvite).
//
//  Per arch reviewer I5: reused per-callsite via `.sheet(isPresented:)` binding,
//  NOT a WindowState global flag. 3 distinct call sites (WorkspaceCreateSheet
//  / SendDirectMessageSheet / AcceptInviteSheet — wired in T4) each own
//  `@State showUpgrade: Bool`.
//
//  Per spec §3 + contract §15.3: scaffold only. Email submit closure is
//  injected at construction site (T4 wires a Supabase `waitlist` PostgREST
//  INSERT via anon JWT — RLS `WITH CHECK true` accepts the insert). T3 ships
//  the view shell only; behaviour exercised via SwiftUI Preview + T4 wiring
//  smoke.
//

import SwiftUI
import LeafCore

/// Reason for showing UpgradeModal — drives headline copy.
enum UpgradeReason {
    case createWorkspace
    case sendMessage
    case acceptInvite

    var headline: String {
        switch self {
        case .createWorkspace: return "Create a workspace with Leaf Team"
        case .sendMessage:     return "Send direct messages with Leaf Team"
        case .acceptInvite:    return "Join a team workspace with Leaf Team"
        }
    }
}

struct UpgradeModal: View {
    let reason: UpgradeReason
    let onDismiss: () -> Void
    let onSubmitEmail: (String) async -> Result<Void, Error>

    @State private var email = ""
    @State private var submitState: SubmitState = .idle

    enum SubmitState: Equatable {
        case idle
        case submitting
        case success
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            // Title
            Text("Upgrade to Team — $30/seat (min 2)")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)

            // Reason copy
            Text(reason.headline)
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)

            // Feature list
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                featureRow(icon: "lock.shield",
                           text: "Encrypted team workspaces (E2E)")
                featureRow(icon: "paperplane.circle",
                           text: "Direct messages — handoff / task / ping")
                featureRow(icon: "rectangle.stack.badge.person.crop",
                           text: "Auto-shared activity feed (commits / Linear / decisions)")
            }

            // Email capture
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text("Stripe billing coming soon — drop your email for early access:")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                HStack(spacing: LeafSpace.sm) {
                    TextField("you@example.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSubmitting || isSuccess)
                    LeafButton(
                        "Get early access",
                        variant: .primary,
                        size: .md,
                        isLoading: isSubmitting,
                        action: submit
                    )
                    .disabled(email.isEmpty || isSubmitting || isSuccess)
                }
            }

            // Status
            statusView

            // Dismiss
            HStack {
                Spacer()
                LeafButton(
                    isSuccess ? "Close" : "Maybe later",
                    variant: .secondary,
                    size: .md,
                    action: onDismiss
                )
            }
        }
        .padding(LeafSpace.xl)
        .frame(width: 460)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func featureRow(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LeafSpace.sm) {
            Image(systemName: icon)
                .foregroundStyle(LeafColor.accent.primary)
                .frame(width: 18, alignment: .center)
            Text(text)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.primary)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch submitState {
        case .idle:
            EmptyView()
        case .submitting:
            EmptyView()  // LeafButton's own isLoading covers spinner
        case .success:
            Label("Thanks — we'll be in touch!", systemImage: "checkmark.circle.fill")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.status.success)
        case .failure(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.status.danger)
        }
    }

    private var isSubmitting: Bool {
        if case .submitting = submitState { return true } else { return false }
    }

    private var isSuccess: Bool {
        if case .success = submitState { return true } else { return false }
    }

    private func submit() {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submitState = .submitting
        Task {
            let result = await onSubmitEmail(trimmed)
            await MainActor.run {
                switch result {
                case .success:
                    submitState = .success
                case .failure(let err):
                    submitState = .failure(err.localizedDescription)
                }
            }
        }
    }
}
