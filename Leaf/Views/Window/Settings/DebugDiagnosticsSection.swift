//
//  DebugDiagnosticsSection.swift
//  fix/dev-launch-reliability — Settings → Diagnostics.
//
//  Visible (not #if DEBUG) panel for figuring out "why isn't it detecting"
//  without digging through logs. Three groups: Main app / Agent / Capture. Refresh — manual.
//

import AppKit
import LeafCore
import SwiftUI

struct DebugDiagnosticsSection: View {
    @Environment(DebugDiagnosticsService.self) private var service
    @Environment(PermissionsService.self) private var permissions
    @Environment(AgentWatchdogService.self) private var watchdog
    @State private var didCopy = false
    @State private var isRepairing = false

    var body: some View {
        LeafSection(
            title: "Diagnostics",
            description:
                "Что-то не детектится? Эта панель показывает кто запущен, какой CDHash, есть ли AX trust, и пишутся ли события в БД. Используется при отладке."
        ) {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                if service.snapshot.agentJobInfo?.isCrashLooping == true {
                    LeafBanner(
                        tone: .danger,
                        title: "Agent crash-loops в launchd",
                        description:
                            "launchd рестартует агента по кругу (non-zero exit). Типичная причина — BTM-запись указывает на старую/переехавшую копию приложения. Repair перерегистрирует агента от этой копии и перезапустит его.",
                        ctaTitle: isRepairing ? "Repairing…" : "Repair",
                        onCTA: { runRepair() }
                    )
                }
                if let escalation = watchdog.escalation {
                    LeafBanner(
                        tone: .danger,
                        title: escalation.title,
                        description: escalation.message,
                        ctaTitle: escalation.needsLoginItemsApproval
                            ? "Open Login Items"
                            : (isRepairing ? "Repairing…" : "Repair"),
                        onCTA: {
                            if escalation.needsLoginItemsApproval {
                                service.openLoginItems()
                            } else {
                                runRepair()
                            }
                        }
                    )
                }
                if service.snapshot.btmLikelyDisabled {
                    LeafBanner(
                        tone: .warning,
                        title: "Agent не запускается — BTM parent disabled",
                        description:
                            "macOS Sequoia recurring bug: после sleep/wake или rebuild Login Items toggle ON визуально, но в BTM disabled. Открой Login Items → toggle OFF → подожди 3с → toggle ON.",
                        ctaTitle: "Open Login Items",
                        onCTA: service.openLoginItems
                    )
                }
                if service.snapshot.cdHashMismatch {
                    LeafBanner(
                        tone: .warning,
                        title: "CDHash mismatch",
                        description:
                            "Main app и Agent подписаны разными identity. Один из бинарников от старого install — пересобрать оба через `just dev` и перезапустить."
                    )
                }
                mainAppCard
                agentCard
                captureCard
                actionsRow
            }
        }
        .onAppear { service.refresh() }
    }

    // MARK: - Main app

    private var mainAppCard: some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("Main app")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                LabeledRow(
                    label: "Bundle path",
                    value: service.snapshot.mainBundlePath,
                    monospaced: true,
                    actionLabel: "Reveal",
                    action: { service.revealInFinder(service.snapshot.mainBundlePath) }
                )
                LabeledRow(
                    label: "CDHash",
                    value: DebugDiagnosticsService.formatHashShort(service.snapshot.mainCDHash),
                    monospaced: true,
                    actionLabel: nil,
                    action: nil
                )
                axTrustRow(
                    label: "AX trusted",
                    granted: service.snapshot.mainAXTrusted,
                    grantAction: { granted in
                        if !granted {
                            permissions.triggerAXPrompt()
                            permissions.openAXSettings()
                        }
                    }
                )
            }
        }
    }

    // MARK: - Agent

    private var agentCard: some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("Agent")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                if let h = service.snapshot.agentHeartbeat {
                    LabeledRow(label: "PID", value: "\(h.pid)", monospaced: true, actionLabel: nil, action: nil)
                    LabeledRow(
                        label: "Bundle path",
                        value: h.bundlePath,
                        monospaced: true,
                        actionLabel: "Reveal",
                        action: { service.revealInFinder(h.bundlePath) }
                    )
                    LabeledRow(
                        label: "CDHash",
                        value: DebugDiagnosticsService.formatHashShort(h.cdHash),
                        monospaced: true,
                        actionLabel: nil,
                        action: nil
                    )
                    axTrustRow(label: "AX trusted", granted: h.axTrusted, grantAction: nil)
                    LabeledRow(
                        label: "Heartbeat",
                        value: h.isStale()
                            ? "\(Int(h.ageSec))s ago (STALE)"
                            : "\(Int(h.ageSec))s ago",
                        monospaced: false,
                        valueColor: h.isStale() ? LeafColor.status.danger : LeafColor.text.tertiary,
                        actionLabel: nil,
                        action: nil
                    )
                } else {
                    Text("No heartbeat file — Agent not running, либо `just dev` ещё не запущен.")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.status.warning)
                    Text(service.snapshot.agentHeartbeatPath.path)
                        .font(LeafType.mono.small)
                        .foregroundStyle(LeafColor.text.tertiary)
                }
                if let job = service.snapshot.agentJobInfo {
                    LabeledRow(
                        label: "launchd",
                        value: launchdSummary(job),
                        monospaced: true,
                        valueColor: job.isCrashLooping
                            ? LeafColor.status.danger : LeafColor.text.secondary,
                        actionLabel: nil,
                        action: nil
                    )
                }
            }
        }
    }

    private func launchdSummary(_ job: AgentJobInfo) -> String {
        let state = job.state ?? "—"
        let runs = job.runs.map(String.init) ?? "—"
        let exit = job.lastExitCode.map(String.init) ?? "—"
        let loop = job.isCrashLooping ? " (CRASH LOOP)" : ""
        return "state=\(state) · runs=\(runs) · last exit=\(exit)\(loop)"
    }

    private func runRepair() {
        guard !isRepairing else { return }
        isRepairing = true
        Task {
            await watchdog.repairNow()
            service.refresh()
            isRepairing = false
        }
    }

    // MARK: - Capture

    private var captureCard: some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("Capture")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                LabeledRow(
                    label: "DB path",
                    value: service.snapshot.dbURL.path,
                    monospaced: true,
                    actionLabel: "Reveal",
                    action: { service.revealInFinder(service.snapshot.dbURL.path) }
                )
                LabeledRow(
                    label: "DB size",
                    value: service.snapshot.dbExists
                        ? DebugDiagnosticsService.formatBytes(service.snapshot.dbSizeBytes)
                        : "missing",
                    monospaced: false,
                    actionLabel: nil,
                    action: nil
                )
                LabeledRow(
                    label: "WAL size",
                    value: DebugDiagnosticsService.formatBytes(service.snapshot.walSizeBytes),
                    monospaced: false,
                    actionLabel: nil,
                    action: nil
                )
                if let total = service.snapshot.totalEvents {
                    LabeledRow(
                        label: "Events total",
                        value: "\(total)",
                        monospaced: false,
                        valueColor: total == 0 ? LeafColor.status.warning : LeafColor.text.secondary,
                        actionLabel: nil,
                        action: nil
                    )
                }
                if let age = service.snapshot.lastEventAgeSec {
                    LabeledRow(
                        label: "Last event",
                        value: DebugDiagnosticsService.formatAge(age),
                        monospaced: false,
                        actionLabel: nil,
                        action: nil
                    )
                }
                if let n = service.snapshot.eventsLastMinute {
                    LabeledRow(
                        label: "Events / min",
                        value: "\(n)",
                        monospaced: false,
                        valueColor: n == 0 ? LeafColor.status.warning : LeafColor.status.success,
                        actionLabel: nil,
                        action: nil
                    )
                }
                if let err = service.snapshot.dbReadError {
                    LeafBanner(
                        tone: .danger,
                        title: "DB read failed",
                        description: err
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private var actionsRow: some View {
        HStack(spacing: LeafSpace.md) {
            LeafButton(
                "Refresh",
                variant: .secondary,
                size: .sm,
                action: { service.refresh() }
            )
            LeafButton(
                didCopy ? "Copied" : "Copy diagnostics",
                variant: .secondary,
                size: .sm,
                action: {
                    service.copyToClipboard()
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        didCopy = false
                    }
                }
            )
            LeafButton(
                "Open Console.app",
                variant: .secondary,
                size: .sm,
                action: { service.openConsoleApp() }
            )
            LeafButton(
                isRepairing ? "Repairing…" : "Repair agent",
                variant: .secondary,
                size: .sm,
                action: { runRepair() }
            )
            Spacer()
        }
    }

    // MARK: - Sub-components

    private func axTrustRow(
        label: String,
        granted: Bool,
        grantAction: ((Bool) -> Void)?
    ) -> some View {
        HStack(spacing: LeafSpace.sm) {
            Text(label)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .frame(width: 100, alignment: .leading)
            Text(granted ? "✓ granted" : "✗ denied")
                .font(LeafType.body.small)
                .foregroundStyle(granted ? LeafColor.status.success : LeafColor.status.danger)
            Spacer()
            if !granted, let grantAction {
                LeafButton(
                    "Grant",
                    variant: .secondary,
                    size: .sm,
                    action: { grantAction(granted) }
                )
            }
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    let monospaced: Bool
    var valueColor: Color = LeafColor.text.secondary
    let actionLabel: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LeafSpace.sm) {
            Text(label)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(monospaced ? LeafType.mono.small : LeafType.body.small)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
            if let actionLabel, let action {
                LeafButton(actionLabel, variant: .secondary, size: .sm, action: action)
            }
        }
    }
}
