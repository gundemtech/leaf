//
//  LocalMessageNotifier.swift
//  Leaf
//
//  Side-effecting half of the incoming-DM local-notification feature: takes a
//  `MessageNotificationPlan` (built by the pure `IncomingMessageNotificationDecider`
//  in LeafCore) and schedules a `UNNotificationRequest`. Mirrors the
//  `NotificationPresentationDecider` (pure, LeafCore) + `foregroundPresentationOptions`
//  (side-effect, app) split — UserNotifications stays out of LeafCore.
//
//  The menubar app is effectively always running, so firing locally from the
//  realtime / polling funnel is the primary delivery mechanism; server-side APNs
//  (`apns_push` Edge Function) covers the app-fully-quit case once deployed. The
//  stable `leaf.dm.<messageID>` identifier lets a future APNs push set
//  `apns-collapse-id = <messageID>` to coalesce rather than stack duplicates.
//
//  Dev-build caveat (matches the NotificationsSettingsSection test-banner note):
//  ad-hoc-signed builds from DerivedData may not register with `usernotificationsd`,
//  so `add(_:)` silently no-ops. The feature is verified on a signed /Applications
//  build; the gating/dedup logic is covered by LeafCore unit tests independently.
//

import Foundation
import LeafCore
import UserNotifications

@MainActor
final class LocalMessageNotifier {

  /// Schedule an immediate local banner for an incoming DM. `userInfo` carries the
  /// same keys the APNs path uses (`leaf_message_id` / `leaf_workspace_id`) so a
  /// banner tap routes through the existing `LeafAppDelegate.userNotificationCenter
  /// (didReceive:)` deep-link unchanged.
  func schedule(_ plan: MessageNotificationPlan) {
    let content = UNMutableNotificationContent()
    content.title = plan.title
    content.body = plan.body
    content.categoryIdentifier = plan.categoryID
    if plan.soundEnabled { content.sound = .default }
    content.userInfo = [
      "leaf_message_id": plan.messageID,
      "leaf_workspace_id": plan.workspaceID,
    ]
    // trigger: nil → deliver immediately. willPresent still applies the user's
    // foreground Behavior prefs (respectFocus / coalesce / sound) on top.
    let request = UNNotificationRequest(
      identifier: plan.identifier, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
  }
}
