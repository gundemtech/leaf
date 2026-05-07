//
//  PendingInvitesSection.swift
//  Leaf
//
//  Phase 5.5.C — TeamView section between active members list и [Add member] CTA.
//  Hidden when no visible rows (D6). Section header has [↻ Refresh] button (batch-poll
//  via PendingInvitesReader.poll()). Per-row actions delegated to PendingInviteRow.
//

import SwiftUI
import LeafCore

struct PendingInvitesSection: View {
    @Environment(PendingInvitesReader.self) private var reader

    var body: some View {
        switch reader.state {
        case .loading:
            EmptyView()
        case .error(let message):
            errorBanner(message)
        case .loaded(let rows) where rows.isEmpty:
            EmptyView()
        case .loaded(let rows):
            content(rows)
        }
    }

    // MARK: - Subviews

    private func content(_ rows: [PendingInvite]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("PENDING INVITES · \(rows.count)")
                    .leafLabelStyle()
                Spacer()
                refreshButton
            }

            VStack(spacing: 12) {
                ForEach(rows, id: \.token) { invite in
                    GlassCard(padding: 18) {
                        PendingInviteRow(
                            invite: invite,
                            onRevoke: { reader.revoke(token: invite.token) },
                            onDismiss: { reader.dismiss(token: invite.token) }
                        )
                    }
                }
            }
            .frame(maxWidth: 580, alignment: .leading)

            if let message = reader.pollMessage {
                pollOutcomeBanner(message: message)
            }
        }
    }

    private var refreshButton: some View {
        Button {
            reader.poll()
        } label: {
            if reader.isPolling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Refreshing…")
                }
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.bordered)
        .disabled(reader.isPolling)
    }

    private func pollOutcomeBanner(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(.leafAccentDeep)
            Text(message)
                .font(.leafBody)
                .foregroundStyle(.leafInk)
            Spacer()
            Button(action: { reader.acknowledgePollMessage() }) {
                Image(systemName: "xmark")
                    .foregroundStyle(.leafInk.opacity(0.5))
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color.leafAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 580, alignment: .leading)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PENDING INVITES")
                .leafLabelStyle()
            GlassCard(padding: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red.opacity(0.85))
                    Text(message)
                        .font(.leafBody)
                        .foregroundStyle(.leafInk)
                    Spacer()
                    Button("Retry") { reader.refresh() }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 580, alignment: .leading)
        }
    }
}
