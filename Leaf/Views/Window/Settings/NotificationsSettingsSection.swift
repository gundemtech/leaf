//
//  NotificationsSettingsSection.swift
//  Track 5 / S8 / T9 — 4 sub-grouped toggles × 11 prefs per Track 5
//  contract §10.2. Binds to NotificationPrefsReader.
//
//  Sub-groups (top→bottom):
//    1. Direct messages — handoff (LOCKED ON) / task / ping
//    2. Auto-detected — decision / blocker / open question / where stopped
//    3. Raw activity — combined commit/Linear/Slack-mention switch
//    4. Behavior — respect macOS Focus / coalesce / sound
//
//  Locked-kind UX: `.handoff` row renders a small lock icon next to the
//  label + the Toggle is `.disabled(true)`. The lock invariant is enforced
//  defence-in-depth at NotificationPrefsStore.setEnabled (throws
//  `cannotDisableLockedKind` if a future code path still tries).
//
//  Each toggle write hits the writer Database (`setNotificationPref`) +
//  best-effort Supabase mirror (`upsertNotificationPref` — apns_push reads
//  the server row to skip pushes for disabled kinds).
//

import LeafCore
import SwiftUI
import UserNotifications

struct NotificationsSettingsSection: View {
  @Environment(NotificationPrefsReader.self) private var reader

  /// Surfaces the most recent dev-test notification attempt outcome
  /// (granted / not-granted / scheduled / error). Kept scoped to this
  /// section so the rest of Settings is unaffected.
  @State private var testStatus: String?

  var body: some View {
    LeafSection(
      title: "Notifications",
      description:
        "Per-kind notification controls. Handoff is always on — receiving a teammate's handoff is the primitive that makes async work feasible. Everything else is opt-in."
    ) {
      VStack(alignment: .leading, spacing: LeafSpace.lg) {
        subGroup(
          title: "Direct messages",
          description: "Pushes from teammates via the workspace direct-message channel.",
          kinds: [.handoff, .task, .ping]
        )
        subGroup(
          title: "Auto-detected",
          description:
            "Pushes when Leaf detects something in your activity that another teammate may want to act on.",
          kinds: [.decision, .blocker, .openQuestion, .whereStopped]
        )
        subGroup(
          title: "Raw activity",
          description:
            "Surfaces commit, Linear, and Slack mention events as pushes when posted by teammates.",
          kinds: [.rawActivity]
        )
        subGroup(
          title: "Behavior",
          description: "How and when Leaf delivers the pushes you've opted into above.",
          kinds: [.respectFocus, .coalesce, .sound]
        )
        #if DEBUG
          testDeliveryRow
        #endif
      }
    }
    .onAppear { reader.refresh() }
  }

  /// Dev-only — fires three local notifications (handoff DM + Task DM
  /// with Mark Done action + invite-request with Approve/Decline) using
  /// the SAME `UNNotificationCategory` identifiers that production APNs
  /// payloads carry, so the action-button UX can be exercised without
  /// a signed build + two-Mac setup + Supabase round-trip.
  ///
  /// macOS quirk: notifications only appear as banners when the app is
  /// in the BACKGROUND. We schedule with a 5-second trigger so the user
  /// has time to ⌘-Tab away after tapping the button.
  @ViewBuilder
  private var testDeliveryRow: some View {
    VStack(alignment: .leading, spacing: LeafSpace.xs) {
      HStack(spacing: LeafSpace.sm) {
        LeafButton("Send test notifications", variant: .secondary, size: .sm) {
          fireTestNotifications()
        }
        if testStatusIsError {
          LeafButton("Open System Settings", variant: .secondary, size: .sm) {
            if let url = URL(
              string: "x-apple.systempreferences:com.apple.preference.notifications")
            {
              NSWorkspace.shared.open(url)
            }
          }
        }
        Spacer()
      }
      Text(
        "Dev-only — schedules 3 local notifications in 5 s (Handoff + Task + Invite request) so the Approve / Decline / Mark Done buttons can be exercised without a signed build. ⌘-Tab away to see banners."
      )
      .font(LeafType.caption)
      .foregroundStyle(LeafColor.text.tertiary)
      if let status = testStatus {
        Text(status)
          .font(LeafType.caption)
          .foregroundStyle(
            testStatusIsError ? LeafColor.status.danger : LeafColor.status.success
          )
      }
    }
    .padding(.top, LeafSpace.md)
  }

  /// Mirrors the colouring branch — `true` when the surfaced status is a
  /// permission denial / system-block (so we render danger colour + show
  /// the [Open System Settings] escape hatch) rather than a success path.
  private var testStatusIsError: Bool {
    guard let status = testStatus else { return false }
    return status.contains("denied") || status.contains("blocked")
      || status.contains("not granted") || status.contains("error")
      || status.contains("Unknown")
  }

  private func fireTestNotifications() {
    let center = UNUserNotificationCenter.current()
    // Look up the current authorization first. `requestAuthorization` on a
    // permanently-denied bundle (Settings → Notifications → Leaf off, or the
    // bundle never got registered with the daemon because the dev build runs
    // from DerivedData with an ad-hoc signature) returns the generic
    // «Notifications are not allowed for this application» error and gives
    // the user nowhere to go. Branching on the cached state lets us surface
    // an actionable [Open System Settings] link instead.
    center.getNotificationSettings { settings in
      // Capture only the Sendable enum value — `UNNotificationSettings`
      // itself isn't Sendable under Swift 6 strict concurrency.
      let status = settings.authorizationStatus
      DispatchQueue.main.async {
        switch status {
        case .denied:
          testStatus =
            "Notifications denied for Leaf. Open System Settings → Notifications → Leaf → toggle Allow notifications ON, then try again."
        case .notDetermined:
          // First-time ask — request now and on grant, schedule.
          center.requestAuthorization(options: [.alert, .sound, .badge]) {
            granted, error in
            DispatchQueue.main.async {
              if let error {
                testStatus = authorizationErrorMessage(error)
                return
              }
              guard granted else {
                testStatus = "Notifications not granted by user."
                return
              }
              scheduleAllTestBanners()
            }
          }
        case .authorized, .provisional, .ephemeral:
          scheduleAllTestBanners()
        @unknown default:
          testStatus =
            "Unknown notification authorization status — try System Settings → Notifications → Leaf."
        }
      }
    }
  }

  /// Disambiguate the system's «not allowed» errors so the user sees a
  /// recovery path instead of the cryptic default copy.
  private func authorizationErrorMessage(_ error: Error) -> String {
    let ns = error as NSError
    // UNErrorCode 1 = .notificationsNotAllowed. Common on Xcode debug
    // builds run from DerivedData — the bundle never gets registered
    // with `usernotificationsd`, so the daemon refuses everything at
    // request time without even surfacing Leaf in System Settings.
    if ns.domain == "UNErrorDomain" && ns.code == 1 {
      return
        "Notifications blocked at the system level — Leaf isn't registered with the notification daemon. Common on Xcode debug builds from DerivedData (ad-hoc sign). Try: (a) build the app to /Applications via Xcode → Product → Archive, OR (b) System Settings → Notifications → toggle Leaf ON if it's listed."
    }
    return "Authorization error: \(error.localizedDescription)"
  }

  private func scheduleAllTestBanners() {
    scheduleTestBanner(
      id: "leaf-dev-test-handoff",
      title: "Test handoff from Sasha",
      body: "Leaf detected a context handoff",
      categoryID: "leaf.dm.handoff",
      in: 5
    )
    scheduleTestBanner(
      id: "leaf-dev-test-task",
      title: "Test task from Sasha",
      body: "Tap Mark Done to complete it without opening the app.",
      categoryID: "leaf.dm.task",
      in: 6
    )
    scheduleTestBanner(
      id: "leaf-dev-test-invite",
      title: "Test invite from Bob",
      body: "Bob wants to join \u{201C}TestRoom\u{201D}.",
      categoryID: "leaf.invite.request",
      in: 7
    )
    testStatus = "Scheduled. ⌘-Tab away in the next 5 s to see banners."
  }

  private func scheduleTestBanner(
    id: String, title: String, body: String, categoryID: String, in seconds: TimeInterval
  ) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.categoryIdentifier = categoryID
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
    let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
  }

  // MARK: - Sub-groups

  @ViewBuilder
  private func subGroup(
    title: String,
    description: String,
    kinds: [NotificationKind]
  ) -> some View {
    VStack(alignment: .leading, spacing: LeafSpace.sm) {
      VStack(alignment: .leading, spacing: LeafSpace.xxs) {
        Text(title)
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.text.primary)
        Text(description)
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.secondary)
      }
      VStack(spacing: LeafSpace.xs) {
        ForEach(kinds, id: \.self) { kind in
          NotificationPrefRow(kind: kind)
        }
      }
    }
  }
}

private struct NotificationPrefRow: View {
  @Environment(NotificationPrefsReader.self) private var reader
  let kind: NotificationKind

  var body: some View {
    LeafCard(variant: .raised, padding: .regular) {
      HStack(alignment: .center, spacing: LeafSpace.md) {
        VStack(alignment: .leading, spacing: LeafSpace.xxs) {
          HStack(spacing: LeafSpace.xs) {
            Text(kind.displayLabel)
              .font(LeafType.body.regular)
              .foregroundStyle(LeafColor.text.primary)
            if kind.locked {
              Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(LeafColor.text.tertiary)
                .help(
                  "Always on — receiving handoffs is the primitive that makes async work feasible.")
            }
          }
        }
        Spacer(minLength: 0)
        Toggle("", isOn: binding)
          .labelsHidden()
          .toggleStyle(.switch)
          .tint(LeafColor.accent.primary)
          .disabled(kind.locked)
      }
    }
  }

  private var binding: Binding<Bool> {
    Binding(
      get: { reader.isEnabled(kind) },
      set: { newValue in
        Task { await reader.setEnabled(kind, enabled: newValue) }
      }
    )
  }
}
