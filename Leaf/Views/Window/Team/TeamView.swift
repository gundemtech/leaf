import SwiftUI
import LeafCore

struct TeamView: View {
    @Environment(OrgReader.self) private var reader
    @Environment(WindowState.self) private var windowState
    @State private var showingGenerateSheet: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                content
                Spacer(minLength: 0)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reader.refresh() }
        .sheet(isPresented: $showingGenerateSheet) {
            GenerateInviteSheet()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.top, 80)

        case .empty:
            emptyCTA

        case .loaded(_, let members):
            membersList(members)

        case .error(let message):
            errorCard(message: message)
        }
    }

    // MARK: - Empty

    private var emptyCTA: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TEAM")
                    .leafLabelStyle()
                Text("No team yet.")
                    .font(.leafHeadline)
                    .foregroundStyle(.leafInk)
            }

            Text("Create your org first. Once you have one, you’ll see yourself as the admin and can invite teammates.")
                .font(.leafBody)
                .foregroundStyle(.leafInk.opacity(0.85))
                .lineSpacing(4)
                .frame(maxWidth: 540, alignment: .leading)

            Button(action: { windowState.section = .organization }) {
                Text("Go to Organization")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Loaded

    private func membersList(_ members: [TeamMember]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TEAM · \(members.count) MEMBER\(members.count == 1 ? "" : "S")")
                    .leafLabelStyle()
                Text("Your team")
                    .font(.leafHeadline)
                    .foregroundStyle(.leafInk)
            }

            VStack(spacing: 12) {
                ForEach(members, id: \.id) { member in
                    GlassCard(padding: 18) {
                        memberRow(member)
                    }
                }
            }
            .frame(maxWidth: 580, alignment: .leading)

            Button(action: { showingGenerateSheet = true }) {
                Label("Add member", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func memberRow(_ member: TeamMember) -> some View {
        HStack(spacing: 14) {
            avatar(for: member.displayName)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(member.displayName)
                        .font(.leafBody)
                        .foregroundStyle(.leafInk)
                    roleBadge(member.role)
                }
                Text(pubkeyShortHex(member.pubkeyHex))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.leafInk.opacity(0.55))
            }

            Spacer()
        }
    }

    private func avatar(for displayName: String) -> some View {
        let initials = displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        return Circle()
            .fill(Color.leafAccent.opacity(0.2))
            .frame(width: 36, height: 36)
            .overlay(
                Text(initials.isEmpty ? "?" : initials)
                    .font(.leafBody.monospacedDigit())
                    .foregroundStyle(.leafAccentDeep)
            )
    }

    private func roleBadge(_ role: TeamMemberRole) -> some View {
        Text(role.rawValue.uppercased())
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.leafAccent.opacity(0.18), in: Capsule())
            .foregroundStyle(.leafAccentDeep)
    }

    private func pubkeyShortHex(_ hex: String) -> String {
        guard hex.count >= 16 else { return hex }
        let prefix = hex.prefix(8)
        let suffix = hex.suffix(8)
        return "\(prefix)…\(suffix)"
    }

    // MARK: - Error

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TEAM")
                    .leafLabelStyle()
                Text("Something went wrong.")
                    .font(.leafHeadline)
                    .foregroundStyle(.leafInk)
            }

            GlassCard(padding: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(message)
                        .font(.leafBody)
                        .foregroundStyle(.leafInk)
                        .lineSpacing(4)
                    HStack {
                        Spacer()
                        Button("Retry") { reader.refresh() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: 580, alignment: .leading)
        }
    }
}
