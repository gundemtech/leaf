//
//  LeafMessageCardPreview.swift
//  Track 5 / S7 B.8 — TokensPreview entry for LeafMessageCard.
//
//  Variants:
//  1. Inbound Handoff — no hover actions visible (static preview)
//  2. Outbound Task — with read receipt
//  3. Inbound Ping — minimal / no attachment
//  4. Inbound with attachment (metadata loading / nil)
//  5. Inbound with attachment (metadata loaded)
//  6. Outbound with cross-posts (Slack + Linear — success)
//  7. Outbound with cross-post (error case — errorText non-nil)
//  8. Reply threaded hint (body prefixes [Reply])
//

import SwiftUI
import LeafCore

#if DEBUG
struct LeafMessageCardPreview: View {

    // MARK: - Sample data

    private let now = Int64(Date().timeIntervalSince1970 * 1000)

    private func msAgo(minutes: Int) -> Int64 {
        now - Int64(minutes * 60 * 1000)
    }

    // Base inbound row
    private var inboundHandoff: DirectMessageMirrorRow {
        DirectMessageMirrorRow(
            messageID: "msg-001",
            workspaceID: "ws-leaf",
            senderPubkeyHex: String(repeating: "ab", count: 32),
            senderMemberID: "member-dima",
            senderDisplayName: "Alex",
            recipientPubkeyHex: String(repeating: "cd", count: 32),
            kind: .handoff,
            body: "Handoff: LeafMessageCard impl is in B.8. Auth service wired in B.5. Pick up from `feature/track-5-S7-team-ui` HEAD — all tests green.",
            attachment: nil,
            replyTo: nil,
            sentAtMs: msAgo(minutes: 5),
            serverCreatedAtMs: msAgo(minutes: 5),
            readAtMs: nil,
            doneAtMs: nil,
            doneByPubkeyHex: nil,
            direction: .inbound,
            lastSyncedAtMs: now
        )
    }

    private var outboundTask: DirectMessageMirrorRow {
        DirectMessageMirrorRow(
            messageID: "msg-002",
            workspaceID: "ws-leaf",
            senderPubkeyHex: String(repeating: "ef", count: 32),
            senderMemberID: "member-anton",
            senderDisplayName: "Sasha",
            recipientPubkeyHex: String(repeating: "ab", count: 32),
            kind: .task,
            body: "Task: Write pgTAP for the M025 migration — expires_at column + RLS assertion. Needs to pass before S6 acceptance gate.",
            attachment: nil,
            replyTo: nil,
            sentAtMs: msAgo(minutes: 30),
            serverCreatedAtMs: msAgo(minutes: 30),
            readAtMs: msAgo(minutes: 20),
            doneAtMs: nil,
            doneByPubkeyHex: nil,
            direction: .outbound,
            lastSyncedAtMs: now
        )
    }

    private var inboundPing: DirectMessageMirrorRow {
        DirectMessageMirrorRow(
            messageID: "msg-003",
            workspaceID: "ws-leaf",
            senderPubkeyHex: String(repeating: "ab", count: 32),
            senderMemberID: "member-dima",
            senderDisplayName: "Alex",
            recipientPubkeyHex: String(repeating: "ef", count: 32),
            kind: .ping,
            body: "Quick ping — deploy window opens in 15 min. Ready to push relay?",
            attachment: nil,
            replyTo: nil,
            sentAtMs: msAgo(minutes: 2),
            serverCreatedAtMs: msAgo(minutes: 2),
            readAtMs: nil,
            doneAtMs: nil,
            doneByPubkeyHex: nil,
            direction: .inbound,
            lastSyncedAtMs: now
        )
    }

    private var inboundWithAttachmentLoading: DirectMessageMirrorRow {
        DirectMessageMirrorRow(
            messageID: "msg-004",
            workspaceID: "ws-leaf",
            senderPubkeyHex: String(repeating: "ab", count: 32),
            senderMemberID: "member-dima",
            senderDisplayName: "Alex",
            recipientPubkeyHex: String(repeating: "ef", count: 32),
            kind: .handoff,
            body: "PR is up for the relay deploy edge function — look over before merging.",
            attachment: DirectMessageAttachment(
                kind: "github_pr",
                externalRef: "#142",
                displayLabel: "#142"
            ),
            replyTo: nil,
            sentAtMs: msAgo(minutes: 45),
            serverCreatedAtMs: msAgo(minutes: 45),
            readAtMs: nil,
            doneAtMs: nil,
            doneByPubkeyHex: nil,
            direction: .inbound,
            lastSyncedAtMs: now
        )
    }

    private var inboundWithAttachmentLoaded: DirectMessageMirrorRow {
        inboundWithAttachmentLoading   // same row; metadata arg differs in the card call
    }

    private var loadedAttachmentMetadata: AttachmentMetadata {
        AttachmentMetadata(
            title: "feat(relay): slack_post + linear_create_issue real bodies",
            statusLabel: "open",
            statusColorKey: .open,
            authorDisplayName: "dima",
            createdAtMs: msAgo(minutes: 50),
            externalURL: URL(string: "https://github.com/gundemtech/leaf-relay/pull/142")!
        )
    }

    private var outboundWithCrossPosts: DirectMessageMirrorRow {
        DirectMessageMirrorRow(
            messageID: "msg-005",
            workspaceID: "ws-leaf",
            senderPubkeyHex: String(repeating: "ef", count: 32),
            senderMemberID: "member-anton",
            senderDisplayName: "Sasha",
            recipientPubkeyHex: String(repeating: "ab", count: 32),
            kind: .task,
            body: "Sent via cross-post to #leaf-architecture (Slack) and Linear Backend team. Alex is assigned.",
            attachment: nil,
            replyTo: nil,
            sentAtMs: msAgo(minutes: 10),
            serverCreatedAtMs: msAgo(minutes: 10),
            readAtMs: nil,
            doneAtMs: nil,
            doneByPubkeyHex: nil,
            direction: .outbound,
            lastSyncedAtMs: now
        )
    }

    private var successCrossPosts: [CrossPostLogRow] {
        [
            try! CrossPostLogRow(
                messageID: "msg-005",
                platform: "slack",
                externalRef: "#leaf-architecture",
                externalURL: URL(string: "https://slack.com/archives/C123/p456")!,
                postedAtMs: msAgo(minutes: 10),
                errorText: nil
            ),
            try! CrossPostLogRow(
                messageID: "msg-005",
                platform: "linear",
                externalRef: "LEA-128",
                externalURL: URL(string: "https://linear.app/gundem/issue/LEA-128")!,
                postedAtMs: msAgo(minutes: 10),
                errorText: nil
            )
        ]
    }

    private var failedCrossPosts: [CrossPostLogRow] {
        [
            try! CrossPostLogRow(
                messageID: "msg-006",
                platform: "linear",
                externalRef: "LEA-129",
                externalURL: URL(string: "https://linear.app/gundem/issue/LEA-129")!,
                postedAtMs: msAgo(minutes: 3),
                errorText: "rate_limited"
            )
        ]
    }

    private var outboundWithFailedCrossPost: DirectMessageMirrorRow {
        DirectMessageMirrorRow(
            messageID: "msg-006",
            workspaceID: "ws-leaf",
            senderPubkeyHex: String(repeating: "ef", count: 32),
            senderMemberID: "member-anton",
            senderDisplayName: "Sasha",
            recipientPubkeyHex: String(repeating: "ab", count: 32),
            kind: .task,
            body: "Linear cross-post failed (rate limited). Leaf DM delivered OK.",
            attachment: nil,
            replyTo: nil,
            sentAtMs: msAgo(minutes: 3),
            serverCreatedAtMs: msAgo(minutes: 3),
            readAtMs: nil,
            doneAtMs: nil,
            doneByPubkeyHex: nil,
            direction: .outbound,
            lastSyncedAtMs: now
        )
    }

    private var inboundReplyHint: DirectMessageMirrorRow {
        DirectMessageMirrorRow(
            messageID: "msg-007",
            workspaceID: "ws-leaf",
            senderPubkeyHex: String(repeating: "ab", count: 32),
            senderMemberID: "member-dima",
            senderDisplayName: "Alex",
            recipientPubkeyHex: String(repeating: "ef", count: 32),
            kind: .ping,
            body: "[Reply] Ready — push whenever you are.",
            attachment: nil,
            replyTo: "msg-003",
            sentAtMs: msAgo(minutes: 1),
            serverCreatedAtMs: msAgo(minutes: 1),
            readAtMs: nil,
            doneAtMs: nil,
            doneByPubkeyHex: nil,
            direction: .inbound,
            lastSyncedAtMs: now
        )
    }

    // MARK: - Sample actions

    private let inboundActions: [MessageAction] = [.markRead, .reply, .markDone]
    private let outboundActions: [MessageAction] = [.markUnread, .copyText, .viewOriginal]

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                Text("LeafMessageCard")
                    .font(LeafType.title.medium)
                    .foregroundStyle(LeafColor.text.primary)

                sectionLabel("1 · Inbound Handoff (no attachment, actions on hover)")
                LeafMessageCard(
                    row: inboundHandoff,
                    direction: .inbound,
                    crossPosts: [],
                    attachmentMetadata: nil,
                    actions: inboundActions,
                    onAction: { _ in },
                    onAppear: {}
                )

                sectionLabel("2 · Outbound Task (read receipt)")
                LeafMessageCard(
                    row: outboundTask,
                    direction: .outbound,
                    crossPosts: [],
                    attachmentMetadata: nil,
                    actions: outboundActions,
                    onAction: { _ in },
                    onAppear: {}
                )

                sectionLabel("3 · Inbound Ping (minimal)")
                LeafMessageCard(
                    row: inboundPing,
                    direction: .inbound,
                    crossPosts: [],
                    attachmentMetadata: nil,
                    actions: inboundActions,
                    onAction: { _ in },
                    onAppear: {}
                )

                sectionLabel("4 · Inbound with attachment — loading (nil metadata)")
                LeafMessageCard(
                    row: inboundWithAttachmentLoading,
                    direction: .inbound,
                    crossPosts: [],
                    attachmentMetadata: nil,
                    actions: inboundActions,
                    onAction: { _ in },
                    onAppear: {}
                )

                sectionLabel("5 · Inbound with attachment — loaded")
                LeafMessageCard(
                    row: inboundWithAttachmentLoaded,
                    direction: .inbound,
                    crossPosts: [],
                    attachmentMetadata: loadedAttachmentMetadata,
                    actions: inboundActions,
                    onAction: { _ in },
                    onAppear: {}
                )

                sectionLabel("6 · Outbound with cross-posts (Slack + Linear, success)")
                LeafMessageCard(
                    row: outboundWithCrossPosts,
                    direction: .outbound,
                    crossPosts: successCrossPosts,
                    attachmentMetadata: nil,
                    actions: outboundActions,
                    onAction: { _ in },
                    onAppear: {}
                )

                sectionLabel("7 · Outbound with failed cross-post (errorText non-nil)")
                LeafMessageCard(
                    row: outboundWithFailedCrossPost,
                    direction: .outbound,
                    crossPosts: failedCrossPosts,
                    attachmentMetadata: nil,
                    actions: outboundActions,
                    onAction: { _ in },
                    onAppear: {}
                )

                sectionLabel("8 · Inbound reply (replyTo set)")
                LeafMessageCard(
                    row: inboundReplyHint,
                    direction: .inbound,
                    crossPosts: [],
                    attachmentMetadata: nil,
                    actions: inboundActions,
                    onAction: { _ in },
                    onAppear: {}
                )

                TokensInlineSpec(
                    spec: "LeafMessageCard · inbound/outbound · 8 variants",
                    codeSnippet: "LeafMessageCard(row:direction:crossPosts:attachmentMetadata:actions:onAction:onAppear:)"
                )
            }
            .padding(LeafSpace.lg)
        }
        .background(LeafColor.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
        .frame(width: 560)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .leafSectionLabel()
            .foregroundStyle(LeafColor.text.tertiary)
    }
}

#Preview("LeafMessageCard") {
    LeafMessageCardPreview()
        .padding()
}
#endif
