//
//  OnboardingView.swift
//  Leaf
//
//  Phase 3.4 — first-launch UX. 4-step inline state machine рендерится
//  в popover вместо normal MenuBarContent когда `!hasCompletedOnboarding`.
//  Auto-advance через `.onChange(of: permissions.axGranted/fdaGranted)`
//  + 1s polling в onAppear (UX-priority: instant grant detection).
//  'Skip for now' escape hatch на каждом permission step — на случай
//  broken deep-link или передумавшего юзера. Permission banner потом
//  покроет в normal popover.
//

import SwiftUI

enum OnboardingStep: String, CaseIterable {
    case welcome, ax, fda, team, done

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

struct OnboardingView: View {
    @AppStorage("onboardingStep") private var step: OnboardingStep = .welcome
    @Environment(PermissionsService.self) private var permissions
    @Environment(InviteAcceptReader.self) private var inviteAcceptReader
    @Environment(OrgReader.self) private var orgReader
    @State private var showingAcceptSheet: Bool = false
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            stepContent
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            permissions.refresh()
            permissions.startPolling(every: 1.0)
        }
        .onDisappear {
            permissions.stopPolling()
        }
        .onChange(of: permissions.axGranted) { _, granted in
            if step == .ax && granted { step = .fda }
        }
        .onChange(of: permissions.fdaGranted) { _, granted in
            if step == .fda && granted { step = .team }
        }
        .sheet(isPresented: $showingAcceptSheet) {
            AcceptInviteSheet()
                .onDisappear {
                    if case .success = inviteAcceptReader.state {
                        inviteAcceptReader.discardAndReset()
                        step = .done
                    }
                }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(.green)
                Text("Welcome to Leaf")
                    .font(.headline)
                Spacer()
            }
            stepDots
        }
    }

    private var stepDots: some View {
        HStack(spacing: 4) {
            ForEach(OnboardingStep.allCases, id: \.self) { s in
                Circle()
                    .fill(s.index <= step.index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .ax:      axStep
        case .fda:     fdaStep
        case .team:    teamStep
        case .done:    doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Leaf quietly tracks your work — apps, focus sessions, and AI usage — and lives in the menu bar.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Get started") { step = .ax }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var axStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accessibility")
                .font(.subheadline.weight(.semibold))
            Text("Lets Leaf see which app is in front and how long you focus.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Grant Accessibility") {
                    permissions.triggerAXPrompt()
                    permissions.openAXSettings()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                grantStatus(granted: permissions.axGranted)
            }
            Button("Skip for now") { step = .fda }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var fdaStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Full Disk Access")
                .font(.subheadline.weight(.semibold))
            Text("Lets Leaf watch folders like ~/Documents for file activity.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") {
                    permissions.openFDASettings()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                grantStatus(granted: permissions.fdaGranted)
            }
            Button("Skip for now") { step = .team }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var teamStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Team")
                .font(.subheadline.weight(.semibold))
            Text("Has someone invited you to a team? Accept the invite — otherwise skip and create your personal org later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Accept invite") {
                showingAcceptSheet = true
            }
            .buttonStyle(.borderedProminent)
            Button("Skip for now") { step = .done }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("All set", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)
            Text("Leaf is collecting in the background. Open Settings → Folders to add directories you want to track.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Finish") { onDone() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func grantStatus(granted: Bool) -> some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else {
            Text("Waiting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
