import SwiftUI
import LeafCore

struct OrganizationView: View {
    @Environment(OrgReader.self) private var reader
    @State private var nameInput: String = ""
    @State private var showingAcceptSheet: Bool = false

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
        .sheet(isPresented: $showingAcceptSheet) {
            AcceptInviteSheet()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.top, 80)

        case .empty:
            createCTA

        case .loaded(let org, _):
            loadedCard(org: org)

        case .error(let message):
            errorCard(message: message)

        case .removedFromOrg:
            // RootView preempts this state with RemovedFromTeamBanner; this branch
            // is unreachable but required for switch exhaustiveness.
            EmptyView()
        }
    }

    // MARK: - Empty: Create CTA

    private var createCTA: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ORGANIZATION")
                    .leafLabelStyle()
                Text("Create your personal org.")
                    .font(.leafHeadline)
                    .foregroundStyle(.leafInk)
            }

            Text("Solo for now — invite teammates after the org is set up. One org per device; the workspace name is just a label, you can change it later.")
                .font(.leafBody)
                .foregroundStyle(.leafInk.opacity(0.85))
                .lineSpacing(4)
                .frame(maxWidth: 540, alignment: .leading)

            GlassCard(padding: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("WORKSPACE NAME")
                        .leafLabelStyle()
                    TextField("My Workspace", text: $nameInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.leafBody)
                        .onSubmit(submit)
                    HStack {
                        Spacer()
                        Button(action: submit) {
                            Text("Create personal org")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedName.isEmpty)
                    }
                }
            }
            .frame(maxWidth: 580, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                Divider().opacity(0.3)
                    .frame(maxWidth: 580)
                Text("OR JOIN A TEAM")
                    .leafLabelStyle()
                Text("If a teammate invited you, accept the invite instead.")
                    .font(.leafBody)
                    .foregroundStyle(.leafInk.opacity(0.75))
                Button(action: { showingAcceptSheet = true }) {
                    Text("Accept invite")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Loaded: org card

    private func loadedCard(org: Org) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ORGANIZATION")
                    .leafLabelStyle()
                Text(org.name)
                    .font(.leafHeadline)
                    .foregroundStyle(.leafInk)
            }

            GlassCard(padding: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    row(label: "CREATED",
                        value: org.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Divider().opacity(0.3)
                    Text("Single-org-per-device — to switch, wipe local data first.")
                        .font(.leafBody)
                        .foregroundStyle(.leafInk.opacity(0.7))
                        .lineSpacing(3)
                }
            }
            .frame(maxWidth: 580, alignment: .leading)
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).leafLabelStyle()
            Spacer()
            Text(value)
                .font(.leafBody.monospacedDigit())
                .foregroundStyle(.leafInk)
        }
    }

    // MARK: - Error

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ORGANIZATION")
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

    // MARK: - Helpers

    private var trimmedName: String {
        nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        reader.createPersonalOrg(displayName: name)
    }
}
