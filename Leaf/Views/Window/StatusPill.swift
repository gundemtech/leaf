import SwiftUI

/// Toolbar status indicator — "● ACTIVE · L4 · HH:MM:SS" inspired by reference #4.
/// Stage-2 stub: shows static "ACTIVE" placeholder; real session timer wired in Stage 6.
struct StatusPill: View {
    @Environment(InsightsReader.self) private var reader

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.leafAccent)
                .frame(width: 7, height: 7)
            Text("ACTIVE")
                .leafLabelStyle()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .leafGlass(tint: Color.leafAccent.opacity(0.12), cornerRadius: 12)
    }
}
