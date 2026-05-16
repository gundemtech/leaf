//
//  LeafMessageCard.swift
//  Track 5 / S7 B.8 — Atom for rendering a direct message row.
//
//  Visual anatomy (spec §6.1):
//    1. Container: LeafCard(.raised) with outbound/inbound alignment indent
//    2. Header: avatar · sender name · kind icon · timestamp
//    3. Body text (6-line cap)
//    4. Attachment embed (LeafLinkedEventCard .full) — when row.attachment != nil
//    5. Cross-post badges (LeafLinkedEventCard .compact) — when crossPosts non-empty
//    6. Read receipt (outbound only, when readAtMs != nil)
//    7. Hover-reveal action bar (overlay top-trailing)
//    8. Right-click context menu (duplicates actions + copy text)
//    9. Auto-mark-read: 1 500 ms timer via Task; cancelled on disappear
//
//  API substitutions vs original spec:
//    - `row.attachment` is `DirectMessageAttachment?` (not separate `attachment_kind`
//      / `attachment_external_ref` fields — spec referenced wire-format column names;
//      Swift model already unwraps them into a typed struct).
//    - `LeafAvatar` takes `initials: String` (not a member type); size `.sm` (24 pt)
//      is the closest to the 32 pt token — we wrap in a fixed frame to honour token.
//    - `DirectionUI` enum defined here (spec public enum) — kept internal since
//      `DirectMessageMirrorRow.Direction` already carries the value; consumers pass
//      `row.direction` directly via the convenience `init(row:crossPosts:...)`.
//

import SwiftUI
import LeafCore

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
        crossPosts: [CrossPostLogRow],
        attachmentMetadata: AttachmentMetadata?,
        actions: [MessageAction],
        onAction: @escaping (MessageAction) -> Void,
        onAppear: @escaping () -> Void
    ) {
        self.row = row
        self.direction = direction
        self.crossPosts = crossPosts
        self.attachmentMetadata = attachmentMetadata
        self.actions = actions
        self.onAction = onAction
        self.onAppear = onAppear
    }

    // MARK: Body

    public var body: some View {
        HStack(spacing: 0) {
            // Outbound messages are right-aligned: push card to the right
            if direction == .outbound {
                Spacer(minLength: LeafMessageCardTokens.outboundAlignmentPad)
            }

            cardContent
                .overlay(alignment: .topTrailing) {
                    if isHovering && !actions.isEmpty {
                        actionBar
                            .padding(LeafSpace.xs)
                            .transition(.opacity)
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

            // Inbound messages are left-aligned: push card to the left
            if direction == .inbound {
                Spacer(minLength: LeafMessageCardTokens.outboundAlignmentPad)
            }
        }
    }

    // MARK: Card content

    @ViewBuilder
    private var cardContent: some View {
        // Use .tight padding preset (= LeafSpace.md = 12 pt) to honour
        // LeafMessageCardTokens.cardPadding. LeafCard's .regular is 16 pt.
        LeafCard(variant: .raised, padding: .tight) {
            VStack(alignment: .leading, spacing: LeafMessageCardTokens.bodySpacing) {
                headerRow
                bodyText
                if let att = row.attachment {
                    attachmentEmbed(att)
                }
                if !crossPosts.isEmpty {
                    crossPostBadges
                }
                if direction == .outbound, let readMs = row.readAtMs {
                    readReceipt(readMs: readMs)
                }
            }
        }
    }

    // MARK: Header row

    private var headerRow: some View {
        HStack(spacing: LeafSpace.xs) {
            // Avatar — LeafAvatar uses initials; wrap in fixed frame to honour avatarSize token
            LeafAvatar(initials: initials(from: row.senderDisplayName), size: .sm)
                .frame(
                    width: LeafMessageCardTokens.avatarSize,
                    height: LeafMessageCardTokens.avatarSize
                )

            // Sender display name
            Text(row.senderDisplayName)
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
                .lineLimit(LeafMessageCardTokens.senderNameLineLimit)

            // Kind icon
            Image(systemName: kindSymbol(row.kind))
                .font(.system(size: LeafMessageCardTokens.kindIconSize, weight: .regular))
                .foregroundStyle(LeafColor.accent.primary)

            Spacer(minLength: 0)

            // Timestamp — relative
            Text(relativeTimestamp(row.sentAtMs))
                .font(LeafType.caption)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    // MARK: Body text

    private var bodyText: some View {
        Text(row.body)
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.primary)
            .lineLimit(LeafMessageCardTokens.bodyLineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                // Parent can wire onAction(.viewOriginal) for deep-link navigation
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

    private func readReceipt(readMs: Int64) -> some View {
        Text("Read \(relativeTimestamp(readMs))")
            .font(LeafType.caption)
            .foregroundStyle(LeafColor.text.tertiary)
            .frame(maxWidth: .infinity, alignment: .trailing)
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

    /// Human-readable label for each action (context menu).
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

    private func relativeTimestamp(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
