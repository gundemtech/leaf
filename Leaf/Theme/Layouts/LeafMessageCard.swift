//
//  LeafMessageCard.swift
//  Track 5 / S7 B.8 — Atom for rendering a direct message row.
//  Team UI polish — chat-style restyle.
//
//  Visual anatomy:
//    1. Run header (when showsHeader): inbound "Sender · 23m ago" with avatar;
//       outbound "→ Recipient · 23m ago" (the feed is multi-recipient — bubble
//       position alone encodes only "from me", never "to whom").
//    2. Bubble: body text (6-line cap) + optional kind badge (task/handoff;
//       ping is the plain-message default) + attachment embed + cross-post
//       badges. Inbound = raised surface, outbound = subtle accent tint.
//    3. Read receipt "Read Nm ago" (outbound, newest read message of a run —
//       flags computed by TeamFeedPresentation.dmRenderFlags).
//    4. Hover-reveal action bar floats ABOVE the bubble edge (offset token) so
//       it never covers the header timestamp.
//    5. Right-click context menu (duplicates actions + copy text).
//    6. Auto-mark-read: 1 500 ms timer via Task; cancelled on disappear.
//
//  Run grouping (consecutive messages of one conversation) hides repeated
//  headers; headerless bubbles stay aligned via a clear avatar-width spacer.
//  Full date/time of every message is available via tooltip on the bubble.
//

import LeafCore
import SwiftUI

// MARK: - Public types

/// Direction of a direct message for UI alignment purposes.
public enum MessageDirectionUI: Sendable {
    case outbound
    case inbound
}

/// Actions available in the hover bar / context menu of a message card.
public enum MessageAction: Sendable, Hashable {
    case markRead
    case markUnread
    case reply
    case markDone
    case copyText
    case viewOriginal
}

// MARK: - LeafMessageCard

public struct LeafMessageCard: View {

    // MARK: Properties

    public let row: DirectMessageMirrorRow
    public let direction: MessageDirectionUI
    /// Run flags (TeamFeedPresentation.dmRenderFlags). Header = name + time on
    /// the newest message of a run; receipt = "Read Nm ago" once per run.
    public let showsHeader: Bool
    public let showsReceipt: Bool
    /// Resolved recipient name for the outbound header ("→ Alex").
    public let recipientDisplayName: String?
    /// Resolved sender name — raw pubkey hex never reaches this view.
    public let senderDisplayName: String
    /// .relative → "23m ago"; .clock → "14:32" (day lives in the separator).
    public let timestampStyle: FeedTimestampStyle
    public let crossPosts: [CrossPostLogRow]
    public let attachmentMetadata: AttachmentMetadata?
    public let actions: [MessageAction]
    public let onAction: (MessageAction) -> Void
    /// Called after the card has been visible for `autoReadThresholdMs` ms.
    /// Host wires this to `directMessageInboxReader.markRead(messageID:)`.
    public let onAppear: () -> Void

    // MARK: State

    @State private var isHovering: Bool = false
    @State private var autoReadTask: Task<Void, Never>?

    // MARK: Init

    public init(
        row: DirectMessageMirrorRow,
        direction: MessageDirectionUI,
        showsHeader: Bool,
        showsReceipt: Bool,
        recipientDisplayName: String?,
        senderDisplayName: String,
        timestampStyle: FeedTimestampStyle,
        crossPosts: [CrossPostLogRow],
        attachmentMetadata: AttachmentMetadata?,
        actions: [MessageAction],
        onAction: @escaping (MessageAction) -> Void,
        onAppear: @escaping () -> Void
    ) {
        self.row = row
        self.direction = direction
        self.showsHeader = showsHeader
        self.showsReceipt = showsReceipt
        self.recipientDisplayName = recipientDisplayName
        self.senderDisplayName = senderDisplayName
        self.timestampStyle = timestampStyle
        self.crossPosts = crossPosts
        self.attachmentMetadata = attachmentMetadata
        self.actions = actions
        self.onAction = onAction
        self.onAppear = onAppear
    }

    // MARK: Body

    public var body: some View {
        HStack(alignment: .top, spacing: LeafSpace.sm) {
            if direction == .outbound {
                Spacer(minLength: LeafMessageCardTokens.outboundAlignmentPad)
            }

            // Avatar column: inbound only. Headerless messages of a run get a
            // clear spacer so their bubbles stay aligned with the run header's.
            if direction == .inbound {
                if showsHeader {
                    LeafAvatar(initials: initials(from: senderDisplayName), size: .sm)
                } else {
                    Color.clear
                        .frame(width: LeafMessageCardTokens.headerAvatarSize, height: 1)
                }
            }

            VStack(
                alignment: direction == .outbound ? .trailing : .leading,
                spacing: LeafSpace.xxs
            ) {
                if showsHeader {
                    headerLine
                }
                bubble
                    .overlay(alignment: direction == .outbound ? .topTrailing : .topLeading) {
                        if isHovering && !actions.isEmpty {
                            actionBar
                                .offset(y: LeafMessageCardTokens.actionBarYOffset)
                                .transition(.opacity)
                        }
                    }
                if showsReceipt, let readMs = row.readAtMs {
                    receiptLine(readMs: readMs)
                }
            }
            .contextMenu {
                contextMenuItems
            }
            .onHover { hovering in
                withAnimation(LeafMessageCardTokens.actionsRevealAnimation) {
                    isHovering = hovering
                }
            }
            .onAppear {
                scheduleAutoRead()
            }
            .onDisappear {
                cancelAutoRead()
            }

            if direction == .inbound {
                Spacer(minLength: LeafMessageCardTokens.outboundAlignmentPad)
            }
        }
    }

    // MARK: Run header

    /// "Alex Doe · 23m ago" (inbound) | "→ Alex · 23m ago" (outbound).
    private var headerLine: some View {
        HStack(spacing: LeafSpace.xs) {
            Text(
                direction == .outbound
                    ? "→ \(recipientDisplayName ?? "Teammate")"
                    : senderDisplayName
            )
            .font(LeafType.body.small)
            .fontWeight(.semibold)
            .foregroundStyle(LeafColor.text.secondary)
            .lineLimit(LeafMessageCardTokens.senderNameLineLimit)

            Text("·")
                .font(LeafType.caption)
                .foregroundStyle(LeafColor.text.tertiary)

            Text(timestampLabel(row.serverCreatedAtMs))
                .font(LeafType.caption)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    // MARK: Bubble

    private var bubble: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            if row.kind != .ping {
                kindBadge
            }
            bodyText
            if let att = row.attachment {
                attachmentEmbed(att)
            }
            if !crossPosts.isEmpty {
                crossPostBadges
            }
        }
        .padding(LeafMessageCardTokens.cardPadding)
        .background(
            RoundedRectangle(
                cornerRadius: LeafMessageCardTokens.bubbleRadius, style: .continuous
            )
            .fill(direction == .outbound ? LeafColor.accent.subtle : LeafColor.surface.raised)
        )
        .frame(
            maxWidth: LeafTeamFeedTokens.bubbleMaxWidth,
            alignment: direction == .outbound ? .trailing : .leading
        )
        .help(fullDateLabel(row.serverCreatedAtMs))
    }

    /// Small labeled chip for task / handoff kinds — replaces the bare icon
    /// whose meaning wasn't guessable. Ping = plain message, no badge.
    private var kindBadge: some View {
        HStack(spacing: LeafSpace.xxs) {
            Image(systemName: kindSymbol(row.kind))
                .font(.system(size: 11, weight: .medium))
            Text(row.kind == .task ? "Task" : "Handoff")
                .font(LeafType.label)
        }
        .foregroundStyle(LeafColor.accent.primary)
        .accessibilityLabel(row.kind == .task ? "Task" : "Handoff")
    }

    private var bodyText: some View {
        Text(row.body)
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.primary)
            .lineLimit(LeafMessageCardTokens.bodyLineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Attachment embed

    @ViewBuilder
    private func attachmentEmbed(_ att: DirectMessageAttachment) -> some View {
        LeafLinkedEventCard(
            metadata: attachmentMetadata,
            externalRef: att.displayLabel ?? att.externalRef,
            provider: attachmentProvider(from: att.kind),
            style: .full,
            onTap: {
                onAction(.viewOriginal)
            }
        )
    }

    // MARK: Cross-post badges

    private var crossPostBadges: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LeafSpace.xs) {
                ForEach(crossPosts) { cp in
                    LeafLinkedEventCard(
                        metadata: nil,
                        externalRef: cp.externalRef,
                        provider: crossPostProvider(from: cp.platform),
                        style: .compact,
                        onTap: {
                            NSWorkspace.shared.open(cp.externalURL)
                        }
                    )
                }
            }
        }
        .padding(.top, LeafSpace.xs)
    }

    // MARK: Read receipt

    private func receiptLine(readMs: Int64) -> some View {
        Text("Read \(relativeTimestamp(readMs))")
            .font(LeafType.caption)
            .foregroundStyle(LeafColor.text.tertiary)
            .help(fullDateLabel(readMs))
            .accessibilityLabel("Read \(relativeTimestamp(readMs))")
    }

    // MARK: Hover-reveal action bar

    private var actionBar: some View {
        HStack(spacing: LeafSpace.xxs) {
            ForEach(actions, id: \.self) { action in
                LeafIconButton(
                    systemName: actionSymbol(action),
                    variant: .ghost,
                    size: .sm,
                    action: { onAction(action) }
                )
                .help(actionLabel(action))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous)
                .fill(LeafColor.surface.raised)
        )
        .leafElevation(LeafElevation.floating)
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        ForEach(actions, id: \.self) { action in
            Button(actionLabel(action)) { onAction(action) }
        }
        Divider()
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.body, forType: .string)
        }
    }

    // MARK: Auto-mark-read

    private func scheduleAutoRead() {
        cancelAutoRead()
        autoReadTask = Task {
            let ns = LeafMessageCardTokens.autoReadThresholdMs * 1_000_000
            do {
                try await Task.sleep(nanoseconds: ns)
                if !Task.isCancelled {
                    onAppear()
                }
            } catch {
                // Task cancelled — no-op
            }
        }
    }

    private func cancelAutoRead() {
        autoReadTask?.cancel()
        autoReadTask = nil
    }

    // MARK: Helpers — mapping

    /// Derives 1-2 uppercase initials from a display name.
    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    /// SF Symbol for each DirectMessageKind.
    private func kindSymbol(_ kind: DirectMessageKind) -> String {
        switch kind {
        case .handoff: return "figure.run.motion"
        case .task:    return "checklist"
        case .ping:    return "bell"
        }
    }

    /// Maps attachment kind string prefix to AttachmentProvider.
    private func attachmentProvider(from kind: String) -> AttachmentProvider {
        if kind.hasPrefix("github") { return .github }
        if kind.hasPrefix("linear") { return .linear }
        if kind.hasPrefix("slack")  { return .slack }
        return .github   // graceful fallback
    }

    /// Maps cross-post platform string to AttachmentProvider.
    private func crossPostProvider(from platform: String) -> AttachmentProvider {
        switch platform {
        case "slack":  return .slack
        case "linear": return .linear
        case "github": return .github
        default:       return .github
        }
    }

    /// Human-readable label for each action (context menu + hover tooltips).
    private func actionLabel(_ action: MessageAction) -> String {
        switch action {
        case .markRead:     return "Mark Read"
        case .markUnread:   return "Mark Unread"
        case .reply:        return "Reply"
        case .markDone:     return "Mark Done"
        case .copyText:     return "Copy Text"
        case .viewOriginal: return "View Original"
        }
    }

    /// SF Symbol for each action (hover bar).
    private func actionSymbol(_ action: MessageAction) -> String {
        switch action {
        case .markRead:     return "checkmark.circle"
        case .markUnread:   return "circle"
        case .reply:        return "arrowshape.turn.up.left"
        case .markDone:     return "checkmark.circle.fill"
        case .copyText:     return "doc.on.doc"
        case .viewOriginal: return "arrow.up.right.square"
        }
    }

    // MARK: Helpers — formatting

    private func timestampLabel(_ ms: Int64) -> String {
        switch timestampStyle {
        case .relative:
            return relativeTimestamp(ms)
        case .clock:
            return leafMessageCardClockFormatter.string(
                from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
        }
    }

    private func fullDateLabel(_ ms: Int64) -> String {
        leafMessageCardFullFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    private func relativeTimestamp(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return leafMessageCardRelativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

/// File-level caches so per-row `body` rebuilds don't allocate formatters
/// (and the CFLocale inside) each invocation. Realtime DM bursts re-render
/// the whole TeamView feed under @Observable invalidation; these turn an
/// alloc-storm into shared instances.
private let leafMessageCardRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

private let leafMessageCardClockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

private let leafMessageCardFullFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()
