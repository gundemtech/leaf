import SwiftUI
import LeafCore

/// Phase 4.10.B — Home block "Recent sessions". Дополняет Top Apps:
/// per-app aggregate vs per-session с window/file context.
struct RecentSessionsBlock: View {
    let sessions: [ActivitySession]

    private static let limit = 8

    private var topSessions: [ActivitySession] {
        Array(sessions.sorted { $0.start > $1.start }.prefix(Self.limit))
    }

    var body: some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("RECENT SESSIONS · TODAY")
                    .leafLabelStyle()

                if topSessions.isEmpty {
                    Text("No sessions yet — switch between apps or files for a few minutes.")
                        .font(.leafBody)
                        .foregroundStyle(.leafMuted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(topSessions.enumerated()), id: \.element.id) { index, session in
                            SessionRow(session: session)
                                .padding(.vertical, 8)
                            if index < topSessions.count - 1 {
                                Divider().opacity(0.3).padding(.leading, 44)
                            }
                        }
                    }
                }
            }
        }
    }
}
