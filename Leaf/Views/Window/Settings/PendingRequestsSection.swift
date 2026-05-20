//
//  PendingRequestsSection.swift
//  Leaf
//
//  M027 invite-redesign — admin's join-request queue surface.
//  Per-row Approve / Decline + bulk Approve All / Decline All (with
//  confirmation modals per spec §2.4). Lives in Settings → Workspace
//  between ActiveTokensSection and the action buttons row.
//

import SwiftUI
import LeafCore

struct PendingRequestsSection: View {
    @Environment(JoinRequestsReader.self) private var reader

    @State private var bulkApproveConfirming = false
    @State private var bulkDeclineConfirming = false

    var body: some View {
        LeafSection(
            title: "Pending join requests",
            description: "Invitees waiting on your approval. Approve fires a push to them; decline is silent (they learn via in-app status poll)."
        ) {
            VStack(spacing: LeafSpace.md) {
                contentView
            }
        }
        .onAppear { reader.refreshAdminQueue() }
        .confirmationDialog(
            "Approve all pending requests?",
            isPresented: $bulkApproveConfirming,
            actions: {
                Button("Approve all", role: .none) {
                    if case .loaded(let pending) = reader.adminQueue, !pending.isEmpty {
                        reader.approveAll(requests: pending)
                    }
                }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                if case .loaded(let pending) = reader.adminQueue {
                    Text("\(pending.count) request\(pending.count == 1 ? "" : "s") will be approved and each invitee will receive a notification.")
                }
            }
        )
        .confirmationDialog(
            "Decline all pending requests?",
            isPresented: $bulkDeclineConfirming,
            actions: {
                Button("Decline all", role: .destructive) {
                    if case .loaded(let pending) = reader.adminQueue, !pending.isEmpty {
                        reader.declineAll(requestIDs: pending.map(\.requestID))
                    }
                }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                if case .loaded(let pending) = reader.adminQueue {
                    Text("\(pending.count) request\(pending.count == 1 ? "" : "s") will be declined silently (no notification fires).")
                }
            }
        )
    }

    @ViewBuilder
    private var contentView: some View {
        switch reader.adminQueue {
        case .idle, .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, LeafSpace.md)
        case .loaded(let pending):
            if pending.isEmpty {
                emptyState
            } else {
                requestsList(pending)
                if pending.count > 1 {
                    bulkActions(count: pending.count)
                }
            }
        case .error(let message):
            LeafBanner(tone: .danger, title: "Couldn't load pending requests", description: message)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: LeafSpace.sm) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(LeafColor.text.tertiary)
            Text("No pending requests.")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LeafSpace.lg)
    }

    @ViewBuilder
    private func requestsList(_ pending: [JoinRequest]) -> some View {
        VStack(spacing: LeafSpace.sm) {
            ForEach(pending, id: \.requestID) { request in
                requestRow(request)
            }
        }
    }

    @ViewBuilder
    private func requestRow(_ request: JoinRequest) -> some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: LeafSpace.xs) {
                        Text(request.inviteeDisplayName)
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.primary)
                        Text(timeAgo(date: request.createdAt))
                            .font(LeafType.caption)
                            .foregroundStyle(LeafColor.text.tertiary)
                    }
                    Spacer()
                }

                HStack(spacing: LeafSpace.sm) {
                    LeafButton("Decline", variant: .secondary, size: .sm) {
                        reader.decline(requestID: request.requestID)
                    }
                    Spacer()
                    LeafButton("Approve", variant: .primary, size: .sm) {
                        reader.approve(request: request)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bulkActions(count: Int) -> some View {
        HStack(spacing: LeafSpace.sm) {
            LeafButton("Decline all", variant: .secondary, size: .md) {
                bulkDeclineConfirming = true
            }
            Spacer()
            LeafButton("Approve all (\(count))", variant: .primary, size: .md) {
                bulkApproveConfirming = true
            }
        }
        .padding(.top, LeafSpace.sm)
    }

    // MARK: - Helpers

    private func timeAgo(date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Requested \(f.localizedString(for: date, relativeTo: Date()))"
    }
}
