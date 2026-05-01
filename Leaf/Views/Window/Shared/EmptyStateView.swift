import SwiftUI

struct EmptyStateView: View {
    enum Phase {
        case team, organization

        var label: String {
            switch self {
            case .team:         "TEAM · COMING IN PHASE 5"
            case .organization: "ORGANIZATION · COMING SOON"
            }
        }

        var headline: String {
            switch self {
            case .team:         "Ambient awareness for your team."
            case .organization: "Workspace tier."
            }
        }

        var blurb: String {
            switch self {
            case .team:
                "Leaf will surface what teammates are working on right now — opt-in, end-to-end encrypted, with no ability for anyone (admins included) to see beyond what each person chooses to share."
            case .organization:
                "Org-level views land after the team layer — billing, member management, and Org-wide analytics built from the same Derived Insights primitives."
            }
        }

        var bullets: [String] {
            switch self {
            case .team: [
                "Opt-in transparency — your share list is yours.",
                "End-to-end encrypted (AES-GCM + X25519 ECDH).",
                "Cloudflare Durable Objects relay, never sees plaintext.",
                "Right-to-deletion + Invisible mode in your control."
            ]
            case .organization: [
                "Billing + seat management.",
                "Org-wide aggregate analytics (privacy-preserving).",
                "Admin tooling that respects individual share controls."
            ]
            }
        }
    }

    let phase: Phase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(phase.label)
                        .leafLabelStyle()
                    Text(phase.headline)
                        .font(.leafHeadline)
                        .foregroundStyle(.leafInk)
                }

                Text(phase.blurb)
                    .font(.leafBody)
                    .foregroundStyle(.leafInk.opacity(0.85))
                    .lineSpacing(4)
                    .frame(maxWidth: 540, alignment: .leading)

                GlassCard(padding: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ROADMAP")
                            .leafLabelStyle()
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(phase.bullets.enumerated()), id: \.offset) { _, bullet in
                                HStack(alignment: .top, spacing: 10) {
                                    Circle()
                                        .fill(.leafAccent)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 7)
                                    Text(bullet)
                                        .font(.leafBody)
                                        .foregroundStyle(.leafInk)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 580, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
