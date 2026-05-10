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
    enum TeamSubStep: Equatable { case choice, create, join, waiting }
    @State private var teamSubStep: TeamSubStep = .choice
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
        .onChange(of: orgReader.state) { _, newState in
            // Phase 5.5.B — admin path: org create success → .done.
            if step == .team, teamSubStep == .create, case .loaded = newState {
                step = .done
            }
        }
        .onChange(of: inviteAcceptReader.state) { _, newState in
            // Invitee path: invite accept success closes sheet (existing) or deep-link auto-fetch
            // landed on .otpEntry — keep waiting view; on .success — done.
            if step == .team, case .success = newState {
                step = .done
            }
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
                Image.leafAsset(LeafIcons.brand.leafFill)
                    .frame(width: 14, height: 14)
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

    @ViewBuilder
    private var teamStep: some View {
        switch teamSubStep {
        case .choice:
            VStack(alignment: .leading, spacing: 10) {
                Text("Team")
                    .font(.subheadline.weight(.semibold))
                Text("Set up how Leaf shares your work signal with teammates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Create new team") { teamSubStep = .create }
                    .buttonStyle(.borderedProminent)
                Button("Join existing team") { teamSubStep = .join }
                    .buttonStyle(.bordered)
                Button("Skip for now") { step = .done }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        case .create:
            CreateTeamStepView(onCancel: { teamSubStep = .choice })
        case .join:
            JoinTeamStepView(
                onAdvance: { teamSubStep = .waiting },
                onCancel: { teamSubStep = .choice }
            )
        case .waiting:
            WaitingForInviteView(
                onManualPaste: { showingAcceptSheet = true },
                onCancel: { teamSubStep = .join }
            )
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("All set", image: LeafIcons.status.successFill)
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
            Label("Granted", image: LeafIcons.status.successFill)
                .foregroundStyle(.green)
                .font(.caption)
        } else {
            Text("Waiting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
