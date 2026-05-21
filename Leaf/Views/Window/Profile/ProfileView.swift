//
//  ProfileView.swift
//  Track 2 / D4 — migrated to LeafAvatar.lg header + LeafMetricCard stats grid.
//  Caption parameter folded into title (LeafMetricCard substrate doesn't
//  surface caption — title carries unit semantics).
//

import LeafCore
import SwiftUI

struct ProfileView: View {
  @Environment(InsightsReader.self) private var reader

  private var fullName: String {
    let n = NSFullUserName().trimmingCharacters(in: .whitespaces)
    return n.isEmpty ? "Local user" : n
  }

  private var initials: String {
    fullName.first.map { String($0).uppercased() } ?? "?"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LeafSpace.xxl) {
        // Account block moved from Settings — surfaces Join code + Tier chip
        // alongside identity stats. Single profile surface.
        AccountSettingsSection()
        statTiles
        Spacer(minLength: 0)
      }
      .padding(LeafSpace.xxl)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // MARK: - Stat tiles

  @ViewBuilder
  private var statTiles: some View {
    // Pre-fix this view collapsed .loading / .notConfigured / .empty /
    // .error into one friendly "Stats will appear…" copy, so DB
    // failures + decryption errors silently masqueraded as «fresh
    // account, still collecting». Split per case so errors surface
    // with a retry CTA and the not-configured state has its own copy.
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
            "\(snapshot.activeDaysInRow) day\(snapshot.activeDaysInRow == 1 ? "" : "s")"
        )
        LeafMetricCard(
          title: "Deep work streak",
          value: deepStreakDays(snapshot.deepWorkStreak)
        )
        LeafMetricCard(
          title: "Total focus",
          value: deepStreakHours(snapshot.deepWorkStreak)
        )
      }
    case .loading:
      HStack {
        Spacer()
        ProgressView()
        Spacer()
      }
      .padding(.vertical, LeafSpace.lg)
    case .empty(let message), .notConfigured(let message):
      Text(message)
        .font(LeafType.body.regular)
        .foregroundStyle(LeafColor.text.secondary)
    case .error(let message):
      LeafBanner(
        tone: .danger,
        title: "Couldn't load stats",
        description: message,
        ctaTitle: "Try again",
        onCTA: { reader.refresh() }
      )
    }
  }

  /// Day count of the current deep-work streak — parallel format to
  /// Active streak so both cards read as a "N days" pair.
  private func deepStreakDays(_ streak: DeepWorkStreak) -> String {
    if streak.days == 0 { return "—" }
    return "\(streak.days) day\(streak.days == 1 ? "" : "s")"
  }

  /// Total focused time accumulated during the current deep-work streak.
  /// Surfaced as its own card to avoid cramming "Nd Mh Km" into one value
  /// (overflowed the metric card width).
  private func deepStreakHours(_ streak: DeepWorkStreak) -> String {
    if streak.totalSeconds < 60 { return "—" }
    let hours = Int(streak.totalSeconds) / 3600
    let minutes = (Int(streak.totalSeconds) % 3600) / 60
    if hours == 0 { return "\(minutes)m" }
    return "\(hours)h \(minutes)m"
  }
}
