//
//  OnboardingView.swift
//  Leaf
//
//  Phase 3.4 — first-launch UX. 5-step inline state machine рендерится
//  в popover вместо normal MenuBarContent когда `!hasCompletedOnboarding`.
//  Auto-advance через `.onChange(of: permissions.axGranted/fdaGranted)`
//  + 1s polling в onAppear (UX-priority: instant grant detection).
//
//  Track 2 / D4 — inline migration to D1 atoms (LeafType / LeafButton / LeafColor /
//  LeafSpace / LeafIcons). NOT LeafOnboardingStepLayout — popover constraint
//  (320pt fixed, MenuBarExtra contentSize). Step dots: Circles preserved (popover-
//  compact); accent vs border.subtle tint. State machine + .sheet + .onChange chain
//  preserved 1:1.
//

import SwiftUI
import LeafCore

enum OnboardingStep: String, CaseIterable {
    case welcome, ax, fda, observers, aiTools, team, done

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

struct OnboardingView: View {
    @AppStorage("onboardingStep") private var step: OnboardingStep = .welcome
    @Environment(PermissionsService.self) private var permissions
    @Environment(InviteAcceptReader.self) private var inviteAcceptReader
    @Environment(WorkspaceReader.self) private var workspaceReader
    @State private var showingAcceptSheet: Bool = false
    enum TeamSubStep: Equatable { case choice, create, join, waiting }
    @State private var teamSubStep: TeamSubStep = .choice
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            header
            LeafDivider()
            stepContent
        }
        .padding(LeafSpace.lg)
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
        .onChange(of: workspaceReader.state) { _, newState in
            if step == .team, teamSubStep == .create, case .loaded = newState {
                step = .done
            }
        }
        .onChange(of: inviteAcceptReader.state) { _, newState in
            if step == .team, case .joined = newState {
                step = .done
            }
        }
        .sheet(isPresented: $showingAcceptSheet) {
            AcceptInviteSheet()
                .onDisappear {
                    if case .joined = inviteAcceptReader.state {
                        inviteAcceptReader.reset()
                        step = .done
                    }
                }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            HStack(spacing: LeafSpace.xs) {
                Image.leafAsset(LeafIcons.brand.leafFill)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(LeafColor.accent.primary)
                Text("Welcome to Leaf")
                    .font(LeafType.title.small)
                    .foregroundStyle(LeafColor.text.primary)
                Spacer()
            }
            stepDots
        }
    }

    private var stepDots: some View {
        HStack(spacing: LeafSpace.xs) {
            ForEach(OnboardingStep.allCases, id: \.self) { s in
                Circle()
                    .fill(s.index <= step.index ? LeafColor.accent.primary : LeafColor.border.subtle)
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:   welcomeStep
        case .ax:        axStep
        case .fda:       fdaStep
        case .observers: observersStep
        case .aiTools:   aiToolsStep
        case .team:      teamStep
        case .done:      doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("Leaf quietly tracks your work — apps, focus sessions, and AI usage — and lives in the menu bar.")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                LeafButton("Get started", variant: .primary, size: .sm, action: { step = .ax })
            }
        }
    }

    private var axStep: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("Accessibility")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text("Lets Leaf see which app is in front and how long you focus.")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                LeafButton(
                    "Grant Accessibility",
                    variant: .primary,
                    size: .sm,
                    action: {
                        permissions.triggerAXPrompt()
                        permissions.openAXSettings()
                    }
                )
                Spacer()
                grantStatus(granted: permissions.axGranted)
            }
            HStack {
                Spacer()
                LeafButton("Skip for now", variant: .ghost, size: .sm, action: { step = .fda })
            }
        }
    }

    private var fdaStep: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("Full Disk Access")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text("Lets Leaf watch folders like ~/Documents for file activity.")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                LeafButton(
                    "Open System Settings",
                    variant: .primary,
                    size: .sm,
                    action: permissions.openFDASettings
                )
                Spacer()
                grantStatus(granted: permissions.fdaGranted)
            }
            HStack {
                Spacer()
                LeafButton("Skip for now", variant: .ghost, size: .sm, action: { step = .observers })
            }
        }
    }

    // Phase Track-4 S1 — Calendar + Focus permission grant step. Inserted
    // between `.fda` and `.team` per Architecture catch-up spec.
    private var observersStep: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("Calendar & Focus")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text("Lets Leaf see when you're in a meeting or Focus mode — never event titles, attendees, or Focus mode names.")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                LeafButton(
                    "Grant Calendar",
                    variant: .primary,
                    size: .sm,
                    action: {
                        permissions.triggerCalendarPrompt()
                        permissions.openCalendarSettings()
                    }
                )
                Spacer()
                grantStatus(granted: permissions.calendarGranted)
            }
            HStack {
                LeafButton(
                    "Grant Focus",
                    variant: .primary,
                    size: .sm,
                    action: {
                        permissions.triggerFocusPrompt()
                        permissions.openFocusSettings()
                    }
                )
                Spacer()
                grantStatus(granted: permissions.focusGranted)
            }
            HStack {
                Spacer()
                LeafButton("Skip for now", variant: .ghost, size: .sm, action: { step = .aiTools })
            }
        }
    }

    // Track-6 P1 Phase F — opt-in Claude Code hook bridge install during
    // onboarding. Skip path is safe: jsonl floor (always-on, no TCC)
    // continues to capture metadata; the bridge install only adds <50ms
    // emit latency + duration_ms / permission_mode coverage.
    private var aiToolsStep: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("AI tool capture")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text("Leaf can detect when you work with Claude Code. Metadata only — file paths, durations, token counts. Prompts, tool inputs, AI responses — never captured.")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                LeafButton(
                    "Install Claude Code hooks",
                    variant: .primary,
                    size: .sm,
                    action: {
                        installHooks()
                    }
                )
                Spacer()
                installedBadge
            }
            HStack {
                Spacer()
                LeafButton("Skip — use jsonl fallback", variant: .ghost, size: .sm, action: { step = .team })
            }
        }
    }

    @ViewBuilder
    private var installedBadge: some View {
        switch permissions.aiToolsStore.lastInstallResult {
        case .ok:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(LeafColor.status.success)
                Text("Installed").font(LeafType.body.small).foregroundStyle(LeafColor.text.secondary)
            }
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LeafColor.status.danger)
                Text(msg).font(LeafType.body.small).foregroundStyle(LeafColor.text.secondary)
            }
        case .notAttempted:
            EmptyView()
        }
    }

    private func installHooks() {
        let installer = AIToolsHookInstaller()
        Task { @MainActor in
            do {
                let result = try installer.install()
                switch result {
                case .ok:
                    permissions.aiToolsStore.lastInstallResult = .ok
                    permissions.aiToolsStore.setEnabled("claude_code", true)
                    step = .team
                case .partial(let msg), .failed(let msg):
                    permissions.aiToolsStore.lastInstallResult = .failed(msg)
                    // Don't advance — let user see error and retry or skip.
                }
            } catch {
                permissions.aiToolsStore.lastInstallResult = .failed("\(error.localizedDescription)")
            }
        }
    }

    @ViewBuilder
    private var teamStep: some View {
        switch teamSubStep {
        case .choice:
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                Text("Team")
                    .font(LeafType.title.small)
                    .foregroundStyle(LeafColor.text.primary)
                Text("Set up how Leaf shares your work signal with teammates.")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LeafButton("Create new team", variant: .primary, size: .sm, action: { teamSubStep = .create })
                LeafButton("Join existing team", variant: .secondary, size: .sm, action: { teamSubStep = .join })
                HStack {
                    Spacer()
                    LeafButton("Skip for now", variant: .ghost, size: .sm, action: { step = .done })
                }
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
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            LeafIconLabel(
                icon: .asset(LeafIcons.status.successFill),
                title: "All set",
                iconTint: LeafColor.status.success,
                titleStyle: LeafType.title.small
            )
            Text("Leaf is collecting in the background. Open Settings → Folders to add directories you want to track.")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                LeafButton("Finish", variant: .primary, size: .sm, action: onDone)
            }
        }
    }

    @ViewBuilder
    private func grantStatus(granted: Bool) -> some View {
        if granted {
            LeafIconLabel(
                icon: .asset(LeafIcons.status.successFill),
                title: "Granted",
                iconTint: LeafColor.status.success,
                titleStyle: LeafType.body.small
            )
        } else {
            Text("Waiting…")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }
}
