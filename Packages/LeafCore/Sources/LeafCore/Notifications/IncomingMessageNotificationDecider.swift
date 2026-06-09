import Foundation

/// Plan for a local notification to schedule for an incoming direct message.
/// The app's `LocalMessageNotifier` maps this to a `UNNotificationRequest`
/// (keeps UserNotifications out of LeafCore — mirrors the
/// `NotificationPresentation` value type for foreground presentation).
public struct MessageNotificationPlan: Equatable, Sendable {
  /// Stable per-message id `leaf.dm.<messageID>` — a future APNs path setting
  /// `apns-collapse-id = <messageID>` coalesces with this rather than stacking.
  public let identifier: String
  /// `leaf.dm.<kind>` — matches `NotificationCategoryRegistry.Kind.categoryID`
  /// so the existing Reply / Mark Done actions render.
  public let categoryID: String
  public let title: String
  public let body: String
  public let soundEnabled: Bool
  public let workspaceID: String
  public let messageID: String

  public init(
    identifier: String, categoryID: String, title: String, body: String,
    soundEnabled: Bool, workspaceID: String, messageID: String
  ) {
    self.identifier = identifier
    self.categoryID = categoryID
    self.title = title
    self.body = body
    self.soundEnabled = soundEnabled
    self.workspaceID = workspaceID
    self.messageID = messageID
  }
}

/// How much of the message to surface in the banner. `.bodyPreview` shows the
/// decrypted text (the recipient's own DM, like iMessage); `.generic` shows only
/// a neutral verb. The privacy "no bodies" rule is about relay/team egress, not
/// local display to the message's intended recipient.
public enum NotificationBodyStyle: Sendable {
  case generic
  case bodyPreview
}

/// Pure gating + copy for a local notification on an incoming DM. Returns a plan
/// only when a banner SHOULD be scheduled. Deduplication is the caller's job
/// (`DirectMessageInboxReader` owns the notified-id / first-poll-batch sets).
public enum IncomingMessageNotificationDecider {
  /// Banner body cap — ordinary UI constant (not moat).
  public static let bodyPreviewMaxChars = 140

  public static func decide(
    messageID: String,
    workspaceID: String,
    kind: DirectMessageKind,
    direction: DirectMessageMirrorRow.Direction,
    senderDisplayName: String,
    body: String,
    readAtMs: Int64?,
    masterEnabled: Bool,
    kindEnabled: Bool,
    soundEnabled: Bool,
    bodyStyle: NotificationBodyStyle,
    masterCanSilenceHandoff: Bool
  ) -> MessageNotificationPlan? {
    // Hard gates — defence-in-depth (realtime already filters inbound).
    guard direction == .inbound else { return nil }
    guard readAtMs == nil else { return nil }

    // Master + per-kind gating with the locked-handoff policy.
    // handoff is locked-ON (contract §10.2): it ignores `kindEnabled` and is
    // only silenced when the master is off AND the policy allows silencing it.
    if kind == .handoff {
      if !masterEnabled && masterCanSilenceHandoff { return nil }
    } else {
      guard masterEnabled else { return nil }
      guard kindEnabled else { return nil }
    }

    let title = senderDisplayName.isEmpty ? "New \(kindLabel(kind))" : senderDisplayName
    let bodyText: String
    switch bodyStyle {
    case .generic:
      bodyText = kindVerb(kind)
    case .bodyPreview:
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      bodyText = trimmed.isEmpty ? kindVerb(kind) : truncate(trimmed, max: bodyPreviewMaxChars)
    }

    return MessageNotificationPlan(
      identifier: "leaf.dm.\(messageID)",
      categoryID: "leaf.dm.\(kind.rawValue)",
      title: title,
      body: bodyText,
      soundEnabled: soundEnabled,
      workspaceID: workspaceID,
      messageID: messageID
    )
  }

  // MARK: - Copy

  static func kindLabel(_ kind: DirectMessageKind) -> String {
    switch kind {
    case .handoff: return "handoff"
    case .task: return "task"
    case .ping: return "ping"
    }
  }

  static func kindVerb(_ kind: DirectMessageKind) -> String {
    switch kind {
    case .handoff: return "sent you a handoff"
    case .task: return "assigned you a task"
    case .ping: return "pinged you"
    }
  }

  /// Grapheme-safe truncation with an ellipsis. Cap is inclusive of the ellipsis.
  static func truncate(_ s: String, max: Int) -> String {
    guard s.count > max else { return s }
    return String(s.prefix(max - 1)) + "\u{2026}"
  }
}
