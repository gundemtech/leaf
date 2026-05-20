//
//  NotificationCategoryRegistry.swift
//  LeafCore
//
//  Track 5 / S8 / T5 — APNs UNNotificationCategory configuration.
//
//  Single source of truth for the three direct-message categories
//  (handoff / task / ping) bound at app launch via
//  `UNUserNotificationCenter.current().setNotificationCategories(...)`.
//
//  Categories are referenced by the `apns_push` Edge Function via
//  `aps.category = "leaf.dm.<kind>"` (spec §3.5 + contract amendment
//  §10.3 landing in T12). When iOS/macOS matches the category id on a
//  delivered push, the listed `UNNotificationAction`s render as
//  Reply / Mark Done buttons in the banner / Notification Center.
//
//  Action contract (consumed by AppDelegate handlers in T6):
//    • `dm.reply`   — foreground; deep-links to TeamView + focuses reply
//                     textfield via `WindowState.focusReplyField`.
//    • `dm.markDone` — background (no foreground option); optimistic local
//                     mirror UPDATE + Supabase PATCH; retry queue on
//                     network failure via `pending_mark_done` column.
//
//  This module is testable in isolation (LeafCore SPM target): the
//  `UNNotificationCategory` values are configured statically here, so
//  `NotificationCategoryRegistryTests` verifies the configuration without
//  invoking `UNUserNotificationCenter.setNotificationCategories(...)`.
//  The app target invokes the side-effecting registration in
//  `LeafAppDelegate.applicationDidFinishLaunching` reading the same
//  static `all` array.
//

import Foundation
import UserNotifications

public enum NotificationCategoryRegistry {

    // MARK: - Stable contract IDs (consumed by AppDelegate action handlers)

    public static let replyActionID    = "dm.reply"
    public static let markDoneActionID = "dm.markDone"

    // M027 invite-redesign — admin-side notification action IDs (consumed by
    // AppDelegate handlers; foreground so click opens app + scrolls to queue).
    public static let inviteApproveActionID = "invite.approve"
    public static let inviteDeclineActionID = "invite.decline"

    // M027 invite-redesign — category IDs (consumed by apns_push server-side
    // via the categoryForKind() mapping in functions/apns_push/index.ts).
    public static let inviteRequestCategoryID  = "leaf.invite.request"
    public static let inviteApprovedCategoryID = "leaf.invite.approved"

    // MARK: - Direct-message kind → category configuration

    /// Mirrors `DirectMessageKind` value space exactly. We do NOT depend on
    /// the LeafCore Team module's enum here to keep this notification module
    /// self-contained (and to allow Kind enumeration without importing the
    /// full Team substrate during AppDelegate launch path).
    public enum Kind: String, CaseIterable {
        case handoff
        case task
        case ping

        /// Category id format: `leaf.dm.<kind>`. Matched by
        /// `aps.category` in the Edge Function payload (T5 server side).
        public var categoryID: String { "leaf.dm.\(rawValue)" }

        /// Only `task` carries the markDone action — handoff/ping are
        /// reply-only per plan T5 description and the spec amendment.
        public var hasMarkDone: Bool { self == .task }
    }

    // MARK: - Per-kind UNNotificationCategory values
    //
    // Factory functions rather than `static let` constants because
    // `UNNotificationCategory` is not `Sendable` and Swift 6 rejects
    // non-Sendable mutable global statics. Constructing fresh instances
    // per call is fine — `setNotificationCategories(...)` is invoked once
    // at app launch and tests typically call once per assertion.

    public static var handoff: UNNotificationCategory { makeCategory(.handoff) }
    public static var task:    UNNotificationCategory { makeCategory(.task) }
    public static var ping:    UNNotificationCategory { makeCategory(.ping) }

    // MARK: - M027 invite-redesign categories

    /// Admin-side push when an invitee submits a join request. Actions deep-link
    /// to PendingRequestsSection (foreground) — the actual approve/decline flow
    /// runs in the app (ECDH+seal needs unlocked keystore for approve path).
    public static var inviteRequest: UNNotificationCategory {
        let approve = UNNotificationAction(
            identifier: inviteApproveActionID,
            title: "Approve",
            options: [.foreground]
        )
        let decline = UNNotificationAction(
            identifier: inviteDeclineActionID,
            title: "Decline",
            options: [.foreground, .destructive]
        )
        return UNNotificationCategory(
            identifier: inviteRequestCategoryID,
            actions: [approve, decline],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    /// Invitee-side push when admin approves their request. No actions —
    /// tap deep-links to the joined workspace via standard notification tap.
    public static var inviteApproved: UNNotificationCategory {
        UNNotificationCategory(
            identifier: inviteApprovedCategoryID,
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    /// Full set bound at launch via
    /// `UNUserNotificationCenter.current().setNotificationCategories(Set(...))`.
    public static var all: [UNNotificationCategory] {
        [handoff, task, ping, inviteRequest, inviteApproved]
    }

    // MARK: - Internal factory

    private static func makeCategory(_ kind: Kind) -> UNNotificationCategory {
        // Reply action — foreground so click → app open → deep-link via
        // existing AppDelegate `userNotificationCenter(didReceive:)` path +
        // T6 addition `WindowState.focusReplyField = true`.
        let reply = UNNotificationAction(
            identifier: replyActionID,
            title: "Reply",
            options: [.foreground]
        )

        var actions: [UNNotificationAction] = [reply]

        if kind.hasMarkDone {
            // Mark Done — explicitly NO foreground. Click dismisses the
            // notification and the AppDelegate handler runs in the
            // background (PATCH + local mirror UPDATE; pending_mark_done
            // flag on network failure with retry queue per spec §3.5).
            let markDone = UNNotificationAction(
                identifier: markDoneActionID,
                title: "Mark Done",
                options: []
            )
            actions.append(markDone)
        }

        return UNNotificationCategory(
            identifier: kind.categoryID,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }
}
