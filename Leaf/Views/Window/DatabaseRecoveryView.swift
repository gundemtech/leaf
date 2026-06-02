import AppKit
import LeafCore
import SwiftUI

/// Ph C migration-guard recovery surface (D-C4 / R7). Shown — in place of the
/// normal UI on every surface — when the on-disk database carries migrations a
/// newer Leaf build wrote that this (older) build does not recognize. Replaces
/// the cryptic "Couldn't load Home" banner with an explicit, actionable path.
struct DatabaseRecoveryInfo: Equatable {
  /// Sorted migration identifiers present on disk but unknown to this binary.
  let unknownMigrations: [String]
  /// Filesystem path of the incompatible database (for Reveal / reset).
  let dbPath: String

  /// Compact display of the unknown migration numbers, e.g. "028, 029, 030".
  var unknownNumbers: String {
    let nums = unknownMigrations.compactMap { id -> String? in
      let digits = id.prefix { $0.isNumber }
      return digits.isEmpty ? nil : String(digits)
    }
    return nums.isEmpty ? unknownMigrations.joined(separator: ", ") : nums.joined(separator: ", ")
  }
}

struct DatabaseRecoveryView: View {
  let info: DatabaseRecoveryInfo
  @State private var resetError: String?

  var body: some View {
    VStack(spacing: LeafSpace.lg) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 40))
        .foregroundStyle(LeafColor.status.warning)

      Text("Database needs attention")
        .font(.title2.weight(.semibold))

      Text(
        """
        This copy of Leaf is older than the data on disk — this build doesn't \
        recognize migrations: \(info.unknownNumbers).

        Update Leaf to the latest version, or reset local data to continue. \
        Resetting moves the current database to a timestamped backup next to it.
        """
      )
      .font(.body)
      .foregroundStyle(LeafColor.text.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)

      if let resetError {
        Text(resetError)
          .font(.callout)
          .foregroundStyle(LeafColor.status.danger)
          .multilineTextAlignment(.center)
      }

      HStack(spacing: LeafSpace.md) {
        LeafButton("Backup & Reset", variant: .destructive, size: .md) { backupAndReset() }
        LeafButton("Reveal in Finder", variant: .secondary, size: .md) { revealInFinder() }
      }

      LeafButton("Quit", variant: .ghost, size: .md) {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(LeafSpace.xxl)
    .frame(maxWidth: 460)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // The Agent bails (exit 0) on a future-schema DB, so there is no live writer
  // when this view appears — backupAndReset only moves files. We then relaunch
  // a fresh instance so init() runs against the now-empty database.
  private func backupAndReset() {
    do {
      _ = try LeafCore.Database.backupAndReset(at: URL(fileURLWithPath: info.dbPath))
      relaunchApp()
    } catch {
      resetError = "Reset failed: \(error.localizedDescription)"
    }
  }

  private func revealInFinder() {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: info.dbPath)])
  }

  /// Relaunch via a detached shell that waits for this instance to quit, then
  /// reopens the bundle (avoids the same-bundle "already running" launch race).
  private func relaunchApp() {
    let bundlePath = Bundle.main.bundlePath
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "sleep 1; open \"\(bundlePath)\""]
    try? task.run()
    NSApplication.shared.terminate(nil)
  }
}
