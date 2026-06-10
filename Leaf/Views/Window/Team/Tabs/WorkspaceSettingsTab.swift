//
//  WorkspaceSettingsTab.swift
//  Team → Workspace Hub — Settings tab. Ported from the retired
//  Settings → Workspace section (Track 5 / S7 F.2 + F.10):
//
//    • workspace meta card — name editor + created date + member count +
//      «Your role» pill
//    • per-workspace Share Rules (ShareControlsSettingsSection, as-is —
//      self-refreshes on workspace switch)
//    • danger zone — Leave (hidden for solo admin) / Delete Permanently
//      (admin-only) / Wipe cache data (post-leave/delete), with the
//      per-operation error banner
//
//  «+ New Workspace» intentionally dropped from the old action row —
//  creation lives in the sidebar workspace picker and the hub's
//  no-workspace empty state.
//

import CryptoKit
import LeafCore
import SwiftUI

struct WorkspaceSettingsTab: View {
  let active: Workspace
  let members: [TeamMember]

  @Environment(WorkspaceReader.self) private var workspaceReader

  @State private var leavePresented = false
  @State private var deletePresented = false
  /// Track 5 / S8 / T8 — Wipe cache data (hard-wipe) modal trigger.
  @State private var hardWipePresented = false
  @State private var myPubHex: String = ""
  /// S7 Stage 6 fix C-I5 + C-I8 — most recent destructive-op error surfaced
  /// as an inline LeafBanner. Reads the operation outcome from the return
  /// value of `workspaceReader.delete(...)` / `hardDelete(...)` instead of
  /// inspecting reader.state (which conflates fresh op result with stale
  /// prior errors).
  @State private var lastActionError: String?

  private static let createdFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
  }()

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: LeafSpace.xl) {
        metaCard
        ShareControlsSettingsSection()
        dangerZone
      }
      .padding(.bottom, LeafSpace.md)
    }
    .onAppear { loadMyPubHex() }
  }

  // MARK: - Meta card (F.2 port)

  private var viewerIsAdmin: Bool {
    WorkspaceHubPresentation.isViewerAdmin(pubkeyHex: myPubHex, members: members)
  }

  @ViewBuilder
  private var metaCard: some View {
    LeafCard(variant: .raised, padding: .regular) {
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        WorkspaceNameEditor(
          workspaceID: active.id,
          currentName: active.name
        )

        HStack(spacing: LeafSpace.lg) {
          LeafIconLabel(
            icon: .system("calendar"),
            title: "Created \(relativeDate(active.createdAt))",
            iconTint: LeafColor.text.tertiary,
            titleStyle: LeafType.caption
          )

          LeafIconLabel(
            icon: .system("person.2"),
            title: "\(members.count) member\(members.count == 1 ? "" : "s")",
            iconTint: LeafColor.text.tertiary,
            titleStyle: LeafType.caption
          )

          HStack(spacing: LeafSpace.xs) {
            Text("Your role")
              .font(LeafType.caption)
              .foregroundStyle(LeafColor.text.tertiary)
            LeafPill(
              title: viewerIsAdmin ? "Admin" : "Member",
              tone: viewerIsAdmin ? .accent : .neutral
            )
          }
        }
        .foregroundStyle(LeafColor.text.tertiary)
      }
    }
  }

  // MARK: - Danger zone (F.10 port)

  @ViewBuilder
  private var dangerZone: some View {
    // A solo admin owns a workspace nobody else has joined yet — «leaving»
    // would orphan the row with no possibility of rejoin (no one left to
    // re-invite them). Force the destructive path through Delete Permanently
    // instead. Mirrors the guard inside `WorkspaceReader.leaveWorkspace`.
    let soloAdmin = viewerIsAdmin && members.count == 1

    LeafSection(title: "Danger zone") {
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        HStack(spacing: LeafSpace.sm) {
          if !soloAdmin {
            LeafButton("Leave Workspace", variant: .destructive, size: .md) {
              leavePresented = true
            }
          }
          if viewerIsAdmin {
            LeafButton("Delete Permanently", variant: .destructive, size: .md) {
              deletePresented = true
            }
          }
          Spacer(minLength: 0)
        }
        // Track 5 / S8 / T8 — «Wipe cache data» destructive action visible
        // only when the workspace has `left_at_ms` OR `deleted_at_ms` set.
        // Closes S7 C-I7 honest-copy promise («auto-delete after 30 days»)
        // by offering the manual wipe path immediately after Leave or
        // admin Delete. Auto-pruner sweeps abandoned rows on the 30d
        // schedule independently.
        if active.leftAt != nil || active.deletedAt != nil {
          HStack(spacing: LeafSpace.sm) {
            LeafButton(
              "Wipe cache data",
              variant: .destructive,
              size: .md,
              icon: .system("trash.fill")
            ) {
              hardWipePresented = true
            }
            Spacer(minLength: 0)
          }
          .padding(.top, LeafSpace.sm)
        }
        if let err = lastActionError {
          LeafBanner(
            tone: .danger,
            title: "Workspace action failed",
            description: err,
            onDismiss: { lastActionError = nil }
          )
          .padding(.top, LeafSpace.sm)
        }
      }
    }
    .sheet(isPresented: $leavePresented) {
      LeaveWorkspaceConfirmationModal(
        workspaceName: active.name,
        onConfirm: {
          // leaveActiveWorkspace doesn't return a Result yet —
          // the underlying operation is local-only (markLeft +
          // re-resolve active). state.error still drives the
          // failure surface here pending future refactor.
          workspaceReader.leaveActiveWorkspace()
          leavePresented = false
        },
        onCancel: { leavePresented = false }
      )
    }
    .sheet(isPresented: $deletePresented) {
      DeleteWorkspaceConfirmationModal(
        workspaceName: active.name,
        onConfirm: {
          // S7 Stage 6 fix C-I5 + C-I8 — read per-operation outcome from
          // the return value (nil = success; non-nil = surface message).
          let err = await workspaceReader.delete(workspaceID: active.id)
          lastActionError = err
          if err == nil {
            deletePresented = false
          }
        },
        onCancel: { deletePresented = false }
      )
    }
    .sheet(isPresented: $hardWipePresented) {
      WorkspaceHardWipeConfirmationModal(
        workspaceName: active.name,
        onConfirm: {
          let err = await workspaceReader.hardDelete(workspaceID: active.id)
          lastActionError = err
          if err == nil {
            hardWipePresented = false
          }
          return err
        },
        onCancel: { hardWipePresented = false }
      )
    }
  }

  // MARK: - Helpers

  private func relativeDate(_ date: Date) -> String {
    Self.createdFormatter.localizedString(for: date, relativeTo: Date())
  }

  private func loadMyPubHex() {
    guard myPubHex.isEmpty else { return }
    do {
      let priv = try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot())
      myPubHex = priv.publicKey.rawRepresentation
        .map { String(format: "%02x", $0) }.joined()
    } catch {
      myPubHex = ""
    }
  }
}
