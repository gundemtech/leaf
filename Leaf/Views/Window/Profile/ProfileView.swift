//
//  ProfileView.swift
//  Profile surface — Variant B: account identity card (web-dashboard parity) +
//  stat tiles + Danger zone (native delete).
//

import LeafCore
import SwiftUI

struct ProfileView: View {
  @Environment(InsightsReader.self) private var reader
  @Environment(AccountProfileReader.self) private var profileReader
  @Environment(\.accountDeletion) private var accountDeletion

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LeafSpace.xxl) {
        ProfileAccountCard()
        statTiles
        ProfileDangerZone(onDelete: runDeletion)
        Spacer(minLength: 0)
      }
      .padding(LeafSpace.xxl)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task { await profileReader.load() }
  }

  /// Returns nil on success; an error string on failure (shown in the card).
  private func runDeletion() async -> String? {
    do {
      try await accountDeletion.run()
      return nil
    } catch {
      return "Account deletion failed: \(error.localizedDescription)"
    }
  }

  // MARK: - Stat tiles  (unchanged from the previous ProfileView)

  @ViewBuilder
  private var statTiles: some View {
    switch reader.state {
    case .loaded(let snapshot, _):
      LazyVGrid(
        columns: [
          GridItem(.flexible(), spacing: LeafSpace.lg),
          GridItem(.flexible(), spacing: LeafSpace.lg),
          GridItem(.flexible(), spacing: LeafSpace.lg),
        ],
        spacing: LeafSpace.lg
      ) {
        LeafMetricCard(
          title: "Active streak",
          value:
            "\(snapshot.activeDaysInRow) day\(snapshot.activeDaysInRow == 1 ? "" : "s")")
        LeafMetricCard(
          title: "Deep work streak", value: deepStreakDays(snapshot.deepWorkStreak))
        LeafMetricCard(
          title: "Total focus", value: deepStreakHours(snapshot.deepWorkStreak))
      }
    case .loading:
      HStack {
        Spacer()
        ProgressView()
        Spacer()
      }.padding(.vertical, LeafSpace.lg)
    case .empty(let message), .notConfigured(let message):
      Text(message).font(LeafType.body.regular).foregroundStyle(LeafColor.text.secondary)
    case .error(let message):
      LeafBanner(
        tone: .danger, title: "Couldn't load stats", description: message,
        ctaTitle: "Try again", onCTA: { reader.refresh(force: true) })
    }
  }

  private func deepStreakDays(_ streak: DeepWorkStreak) -> String {
    if streak.days == 0 { return "—" }
    return "\(streak.days) day\(streak.days == 1 ? "" : "s")"
  }

  private func deepStreakHours(_ streak: DeepWorkStreak) -> String {
    if streak.totalSeconds < 60 { return "—" }
    let hours = Int(streak.totalSeconds) / 3600
    let minutes = (Int(streak.totalSeconds) % 3600) / 60
    if hours == 0 { return "\(minutes)m" }
    return "\(hours)h \(minutes)m"
  }
}
