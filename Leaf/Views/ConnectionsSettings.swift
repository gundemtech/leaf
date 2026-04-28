//
//  ConnectionsSettings.swift
//  Leaf
//
//  Phase 4.1 — Settings tab "Connections" для third-party data sources.
//  MVP: один provider (Linear). UI шапка нейтральная — после v1.1 (Slack, GitHub)
//  легко расширится в list с rows-per-provider.
//

import SwiftUI

struct ConnectionsSettings: View {
    @Bindable var service: LinearOAuthService

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
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { service.reload() }
    }

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
                Text(progressLabel)
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

    private var progressLabel: String {
        switch service.state {
        case .authorizing: "Preparing authorization…"
        case .waitingForCallback: "Waiting for Linear approval in browser…"
        case .exchangingToken: "Exchanging token…"
        case .fetchingWorkspace: "Loading workspace…"
        default: ""
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
