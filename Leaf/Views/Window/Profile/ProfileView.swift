import SwiftUI
import LeafCore

struct ProfileView: View {
    @Environment(InsightsReader.self) private var reader

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                statTiles
                Spacer(minLength: 0)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                Text("PROFILE")
                    .leafLabelStyle()
                Text("Dmitrii Demidov")
                    .font(.leafHeadline)
                    .foregroundStyle(.leafInk)
                Text("Leaf · Local user")
                    .font(.leafBody)
                    .foregroundStyle(.leafMuted)
            }
            Spacer()
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color.leafAccent.opacity(0.18))
            Text("D")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(.leafAccentDeep)
        }
        .frame(width: 64, height: 64)
        .overlay(Circle().stroke(Color.leafAccent.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Stat tiles

    @ViewBuilder
    private var statTiles: some View {
        if case .loaded(let snapshot, _) = reader.state {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: 16)],
                spacing: 16
            ) {
                MetricCard(
                    title: "Active days",
                    value: "\(snapshot.activeDaysInRow)",
                    caption: "in a row"
                )
                MetricCard(
                    title: "Deep streak",
                    value: snapshot.deepWorkStreak.days == 0 ? "—" : "\(snapshot.deepWorkStreak.days)",
                    caption: snapshot.deepWorkStreak.days == 0
                        ? "no deep streak yet"
                        : formatDuration(snapshot.deepWorkStreak.totalSeconds) + " total"
                )
            }
        } else {
            Text("Stats will appear once the agent collects today's activity.")
                .font(.leafBody)
                .foregroundStyle(.leafMuted)
        }
    }
}
