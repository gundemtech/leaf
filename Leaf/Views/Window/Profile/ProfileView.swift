//
//  ProfileView.swift
//  Track 2 / D4 — migrated to LeafAvatar.lg header + LeafMetricCard stats grid.
//  Caption parameter folded into title (LeafMetricCard substrate doesn't
//  surface caption — title carries unit semantics).
//

import SwiftUI
import LeafCore

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
                header
                statTiles
                Spacer(minLength: 0)
            }
            .padding(LeafSpace.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: LeafSpace.lg) {
            LeafAvatar(initials: initials, size: .lg)
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text(fullName)
                    .font(LeafType.title.medium)
                    .foregroundStyle(LeafColor.text.primary)
                Text("Leaf · Local user")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Stat tiles

    @ViewBuilder
    private var statTiles: some View {
        if case .loaded(let snapshot, _) = reader.state {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: LeafSpace.lg)],
                spacing: LeafSpace.lg
            ) {
                LeafMetricCard(
                    title: "Active streak",
                    value: "\(snapshot.activeDaysInRow) day\(snapshot.activeDaysInRow == 1 ? "" : "s")"
                )
                LeafMetricCard(
                    title: "Deep work streak",
                    value: deepStreakValue(snapshot.deepWorkStreak)
                )
            }
        } else {
            Text("Stats will appear once the agent collects today's activity.")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }

    private func deepStreakValue(_ streak: DeepWorkStreak) -> String {
        if streak.days == 0 { return "—" }
        return "\(streak.days)d \(formatHours(streak.totalSeconds))"
    }

    private func formatHours(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}
