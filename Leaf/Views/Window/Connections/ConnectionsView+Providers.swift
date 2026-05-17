//
//  ConnectionsView+Providers.swift
//  Per-provider content blocks: switches on OAuth state, renders the matching
//  shared block (disconnected / progress / connected / reconnect / error).
//  Covers Google Calendar, Linear, GitHub (incl. Device Flow), Slack.
//

import SwiftUI
import LeafCore

extension ConnectionsView {

    // MARK: - Google Calendar (Track-6 P4)

    @ViewBuilder
    var googleCalendarContent: some View {
        switch googleCalendarOAuth.state {
        case .notConnected:
            disconnectedBlock(
                title: "Not connected",
                description: "Sign in with Google to share meeting metadata (titles, times, attendee counts) into your local timeline.",
                ctaTitle: "Connect Google Calendar",
                action: { Task { await googleCalendarOAuth.connect() } }
            )
        case .authorizing, .waitingForCallback, .exchangingToken, .fetchingWorkspace:
            progressBlock(label: googleCalendarProgressLabel)
        case .connected(let workspaceName, let connectedAt):
            connectedBlock(
                title: workspaceName,
                connectedAt: connectedAt,
                action: { googleCalendarOAuth.disconnect() }
            )
        case .reconnectNeeded:
            reconnectBlock(
                description: "Your Google session expired and Leaf can't refresh it automatically. Sign in again to resume polling.",
                ctaTitle: "Reconnect Google Calendar",
                action: { Task { await googleCalendarOAuth.connect() } }
            )
        case .error(let message):
            errorBlock(
                description: message,
                action: { Task { await googleCalendarOAuth.connect() } }
            )
        }
    }

    var googleCalendarProgressLabel: String {
        switch googleCalendarOAuth.state {
        case .authorizing: "Preparing authorization…"
        case .waitingForCallback: "Waiting for Google approval in browser…"
        case .exchangingToken: "Exchanging token…"
        case .fetchingWorkspace: "Loading primary calendar…"
        default: ""
        }
    }

    // MARK: - Linear

    @ViewBuilder
    var linearContent: some View {
        switch linearOAuth.state {
        case .notConnected:
            disconnectedBlock(
                title: "Not connected",
                description: "Sign in with Linear to share issue activity into your local timeline.",
                ctaTitle: "Connect Linear",
                action: { Task { await linearOAuth.connect() } }
            )
        case .authorizing, .waitingForCallback, .exchangingToken, .fetchingWorkspace:
            progressBlock(label: linearProgressLabel)
        case .connected(let workspaceName, let connectedAt):
            connectedBlock(
                title: workspaceName,
                connectedAt: connectedAt,
                action: { linearOAuth.disconnect() }
            )
        case .reconnectNeeded:
            reconnectBlock(
                description: "Your Linear session expired and Leaf can't refresh it automatically. Sign in again to resume polling.",
                ctaTitle: "Reconnect Linear",
                action: { Task { await linearOAuth.connect() } }
            )
        case .error(let message):
            errorBlock(
                description: message,
                action: { Task { await linearOAuth.connect() } }
            )
        }
    }

    var linearProgressLabel: String {
        switch linearOAuth.state {
        case .authorizing: "Preparing authorization…"
        case .waitingForCallback: "Waiting for Linear approval in browser…"
        case .exchangingToken: "Exchanging token…"
        case .fetchingWorkspace: "Loading workspace…"
        default: ""
        }
    }

    // MARK: - GitHub

    @ViewBuilder
    var githubContent: some View {
        switch githubOAuth.state {
        case .notConnected:
            disconnectedBlock(
                title: "Not connected",
                description: "Sign in with GitHub to share self-authored events into your local timeline.",
                ctaTitle: "Connect GitHub",
                action: { Task { await githubOAuth.connect() } }
            )
        case .requestingDeviceCode:
            progressBlock(label: "Requesting device code…")
        case .awaitingAuthorization(let userCode, let verificationURI, let expiresAt):
            githubDeviceFlowBlock(userCode: userCode, verificationURI: verificationURI, expiresAt: expiresAt)
        case .exchangingToken, .fetchingViewer:
            progressBlock(label: githubProgressLabel)
        case .connected(let login, let connectedAt):
            connectedBlock(
                title: login,
                connectedAt: connectedAt,
                action: { githubOAuth.disconnect() }
            )
        case .connectedScopeOutdated(let login, let connectedAt, _):
            // Phase Track-3 D2 / Task 19 — render header identical to `.connected`
            // (login + connected timestamp + Disconnect). The Scopes section
            // rendered alongside (`scopesSection`) carries the missing-scope
            // banners + Re-authorize CTA, so the connection block itself stays
            // a clean status pill. Re-auth pressure is also surfaced proactively
            // by the Home banner (Task 18) and sidebar red dot (Task 20).
            connectedBlock(
                title: login,
                connectedAt: connectedAt,
                action: { githubOAuth.disconnect() }
            )
        case .reconnectNeeded:
            reconnectBlock(
                description: "Your GitHub session expired and Leaf can't refresh it automatically. Sign in again to resume polling.",
                ctaTitle: "Reconnect GitHub",
                action: { Task { await githubOAuth.connect() } }
            )
        case .error(let message):
            errorBlock(
                description: message,
                action: { Task { await githubOAuth.connect() } }
            )
        }
    }

    var githubProgressLabel: String {
        switch githubOAuth.state {
        case .exchangingToken: "Exchanging token…"
        case .fetchingViewer: "Loading GitHub identity…"
        default: ""
        }
    }

    func githubDeviceFlowBlock(userCode: String, verificationURI: URL, expiresAt: Date) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("Enter this code on GitHub")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text(userCode)
                .font(LeafType.mono.large)
                .foregroundStyle(LeafColor.text.primary)
                .textSelection(.enabled)
            HStack(spacing: LeafSpace.sm) {
                LeafButton(
                    "Open in browser",
                    variant: .primary,
                    size: .sm,
                    action: { NSWorkspace.shared.open(verificationURI) }
                )
                LeafButton(
                    "Copy code",
                    variant: .secondary,
                    size: .sm,
                    action: {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(userCode, forType: .string)
                    }
                )
                LeafButton(
                    "Cancel",
                    variant: .ghost,
                    size: .sm,
                    action: { githubOAuth.cancel() }
                )
            }
            Text(countdownLabel(expiresAt: expiresAt))
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    // MARK: - Slack

    @ViewBuilder
    var slackContent: some View {
        switch slackOAuth.state {
        case .notConnected:
            disconnectedBlock(
                title: "Not connected",
                description: "Sign in with Slack to capture self-authored message counts and huddle minutes into your local timeline.",
                ctaTitle: "Connect Slack",
                action: { Task { await slackOAuth.connect() } }
            )
        case .authorizing, .waitingForCallback, .exchangingToken, .fetchingWorkspace:
            progressBlock(label: slackProgressLabel)
        case .connected(let workspaceName, let connectedAt):
            connectedBlock(
                title: workspaceName,
                connectedAt: connectedAt,
                action: { slackOAuth.disconnect() }
            )
        case .connectedScopeOutdated(let workspaceName, let connectedAt, _):
            // Phase Track-3 D3 — Tasks 19-21 add the dedicated re-auth banner /
            // missing-scopes detail UI. Until then surface as plain connected so
            // the substrate ships без UI regression.
            connectedBlock(
                title: workspaceName,
                connectedAt: connectedAt,
                action: { slackOAuth.disconnect() }
            )
        case .reconnectNeeded:
            reconnectBlock(
                description: "Your Slack session expired and Leaf can't refresh it automatically. Sign in again to resume polling.",
                ctaTitle: "Reconnect Slack",
                action: { Task { await slackOAuth.connect() } }
            )
        case .error(let message):
            errorBlock(
                description: message,
                action: { Task { await slackOAuth.connect() } }
            )
        }
    }

    var slackProgressLabel: String {
        switch slackOAuth.state {
        case .authorizing: "Preparing authorization…"
        case .waitingForCallback: "Waiting for Slack approval in browser…"
        case .exchangingToken: "Exchanging token…"
        case .fetchingWorkspace: "Loading workspace…"
        default: ""
        }
    }
}
