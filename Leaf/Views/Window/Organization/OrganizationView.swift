//
//  OrganizationView.swift
//  Track 2 / D4 — migrated to LeafSection chain + LeafCard.raised + LeafBanner.
//  Drop manual ORGANIZATION / Create-your-personal-org / etc leafLabelStyle headers
//  (LeafSection.title carries hierarchy). emptyContent carries 2 LeafSection blocks
//  (Organization create + Or-join-team). loadedContent carries 1 LeafSection
//  (Organization workspace metadata). error → LeafBanner.danger top.
//

import SwiftUI
import LeafCore

struct OrganizationView: View {
    @Environment(OrgReader.self) private var reader
    @State private var nameInput: String = ""
    @State private var showingAcceptSheet: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xxl) {
                content
                Spacer(minLength: 0)
            }
            .padding(LeafSpace.xxl)
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
                .padding(.top, LeafSpace.xxxl)
        case .empty:
            emptyContent
        case .loaded(let org, _):
            loadedContent(org: org)
        case .error(let message):
            errorContent(message: message)
        case .removedFromOrg:
            // RootView preempts this state with RemovedFromTeamBanner.
            EmptyView()
        }
    }

    // MARK: - Empty: create CTA + or-join

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xxl) {
            LeafSection(
                title: "Organization",
                description: "Create your personal org. Solo for now — invite teammates after the org is set up. One org per device; the workspace name is just a label, you can change it later."
            ) {
                LeafCard(variant: .raised, padding: .regular) {
                    VStack(alignment: .leading, spacing: LeafSpace.md) {
                        Text("WORKSPACE NAME").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                        TextField("My Workspace", text: $nameInput)
                            .textFieldStyle(.roundedBorder)
                            .font(LeafType.body.regular)
                            .onSubmit(submit)
                        HStack {
                            Spacer()
                            LeafButton(
                                "Create personal org",
                                variant: .primary,
                                size: .md,
                                action: submit
                            )
                            .disabled(trimmedName.isEmpty)
                        }
                    }
                }
            }

            LeafSection(
                title: "Or join a team",
                description: "If a teammate invited you, accept the invite instead."
            ) {
                LeafButton(
                    "Accept invite",
                    variant: .secondary,
                    size: .md,
                    action: { showingAcceptSheet = true }
                )
            }
        }
    }

    // MARK: - Loaded: workspace card

    private func loadedContent(org: Org) -> some View {
        LeafSection(title: "Organization") {
            LeafCard(variant: .raised, padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.md) {
                    Text(org.name)
                        .font(LeafType.title.medium)
                        .foregroundStyle(LeafColor.text.primary)
                    LeafDivider()
                    HStack(alignment: .firstTextBaseline) {
                        Text("Created")
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.secondary)
                        Spacer()
                        Text(org.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(LeafType.mono.regular)
                            .foregroundStyle(LeafColor.text.primary)
                    }
                    LeafDivider()
                    Text("Single-org-per-device — to switch, wipe local data first.")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.tertiary)
                }
            }
        }
    }

    // MARK: - Error

    private func errorContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            LeafBanner(
                tone: .danger,
                title: "Couldn't load organization",
                description: message,
                ctaTitle: "Retry",
                onCTA: reader.refresh
            )
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
