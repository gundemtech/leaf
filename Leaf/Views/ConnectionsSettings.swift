//
//  ConnectionsSettings.swift
//  Leaf
//
//  Phase 4.1 — Settings tab "Connections" для third-party data sources.
//  Phase 4.3 — second provider (GitHub Device Flow) added below Linear.
//

import SwiftUI
import Combine

struct ConnectionsSettings: View {
    @Bindable var service: LinearOAuthService
    @Bindable var githubService: GitHubOAuthService

    @State private var nowTick: Date = Date()
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                linearSection
            } header: {
                Text("Linear")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Read-only access — Leaf polls issue updates every 5 minutes (metadata only: issue key, title, status, project). Bodies and comments stay in Linear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Data stays on your device, encrypted with the same key as your local activity DB.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section {
                githubSection
            } header: {
                Text("GitHub")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Read-only access — Leaf polls GitHub events every 5 minutes (metadata only: repo, commit subject, PR/issue title). Bodies, comments and file diffs stay in GitHub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Data stays on your device, encrypted with the same key as your local activity DB.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            service.reload()
            githubService.reload()
        }
        .onReceive(countdownTimer) { now in
            nowTick = now
        }
    }

    // MARK: - Linear section

    @ViewBuilder
    private var linearSection: some View {
        switch service.state {
        case .notConnected:
            VStack(alignment: .leading, spacing: 8) {
                Text("Not connected")
                    .font(.headline)
                Text("Sign in with Linear to share issue activity (assigned, updated, completed) into your local timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Connect Linear") {
                    Task { await service.connect() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.vertical, 4)

        case .authorizing, .waitingForCallback, .exchangingToken, .fetchingWorkspace:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(linearProgressLabel)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

        case .connected(let workspaceName, let connectedAt):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text(workspaceName)
                        .font(.headline)
                }
                Text(connectedLabel(connectedAt: connectedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    service.disconnect()
                } label: {
                    Text("Disconnect")
                }
            }
            .padding(.vertical, 4)

        case .reconnectNeeded:
            VStack(alignment: .leading, spacing: 8) {
                Label("Reconnect needed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text("Your Linear session expired and Leaf can't refresh it automatically. Sign in again to resume polling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reconnect Linear") {
                    Task { await service.connect() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.vertical, 4)

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Try again") {
                    Task { await service.connect() }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - GitHub section

    @ViewBuilder
    private var githubSection: some View {
        switch githubService.state {
        case .notConnected:
            VStack(alignment: .leading, spacing: 8) {
                Text("Not connected")
                    .font(.headline)
                Text("Sign in with GitHub to share self-authored events (commits, PRs, issues, reviews) into your local timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Connect GitHub") {
                    Task { await githubService.connect() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.vertical, 4)

        case .requestingDeviceCode:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Requesting device code…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

        case .awaitingAuthorization(let userCode, let verificationURI, let expiresAt):
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter this code on GitHub")
                    .font(.headline)
                Text(userCode)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                HStack(spacing: 8) {
                    Button("Open in browser") {
                        NSWorkspace.shared.open(verificationURI)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Copy code") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(userCode, forType: .string)
                    }
                    Button("Cancel") {
                        githubService.cancel()
                    }
                }
                Text(countdownLabel(expiresAt: expiresAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

        case .exchangingToken, .fetchingViewer:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(githubProgressLabel)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

        case .connected(let login, let connectedAt):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text(login)
                        .font(.headline)
                }
                Text(connectedLabel(connectedAt: connectedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    githubService.disconnect()
                } label: {
                    Text("Disconnect")
                }
            }
            .padding(.vertical, 4)

        case .reconnectNeeded:
            VStack(alignment: .leading, spacing: 8) {
                Label("Reconnect needed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text("Your GitHub session expired and Leaf can't refresh it automatically. Sign in again to resume polling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reconnect GitHub") {
                    Task { await githubService.connect() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.vertical, 4)

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Try again") {
                    Task { await githubService.connect() }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Labels

    /// `RelativeDateTimeFormatter` для свежей даты возвращает "in 0 seconds" из-за
    /// nanosecond drift между timestamp создания row и rendered Date(). Под 5s
    /// ставим стабильный лейбл; выше — относительный formatter.
    private func connectedLabel(connectedAt: Date) -> String {
        let elapsed = abs(Date().timeIntervalSince(connectedAt))
        if elapsed < 5 {
            return "Just connected"
        }
        return "Connected \(Self.relativeFormatter.localizedString(for: connectedAt, relativeTo: Date()))"
    }

    /// MM:SS countdown до истечения device_code (RFC 8628 §3.2 expiresIn).
    private func countdownLabel(expiresAt: Date) -> String {
        let remaining = max(0, Int(expiresAt.timeIntervalSince(nowTick)))
        let minutes = remaining / 60
        let seconds = remaining % 60
        if remaining <= 0 {
            return "Code expired — try again."
        }
        return String(format: "Code expires in %d:%02d", minutes, seconds)
    }

    private var linearProgressLabel: String {
        switch service.state {
        case .authorizing: "Preparing authorization…"
        case .waitingForCallback: "Waiting for Linear approval in browser…"
        case .exchangingToken: "Exchanging token…"
        case .fetchingWorkspace: "Loading workspace…"
        default: ""
        }
    }

    private var githubProgressLabel: String {
        switch githubService.state {
        case .exchangingToken: "Exchanging token…"
        case .fetchingViewer: "Loading GitHub identity…"
        default: ""
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
