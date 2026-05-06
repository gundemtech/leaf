import SwiftUI

struct RootView: View {
    @Environment(WindowState.self) private var windowState
    @Environment(InsightsReader.self) private var reader
    @Environment(OrgReader.self) private var orgReader

    var body: some View {
        // Phase 5.3.E — full-screen takeover when self is removed from org
        // (tombstone applied by RotationFetchService → OrgReader.refresh
        // surfaces .removedFromOrg state on next read).
        Group {
            if case .removedFromOrg(let orgName) = orgReader.state {
                RemovedFromTeamBanner(orgName: orgName)
            } else {
                normalContent
            }
        }
        .onAppear { orgReader.refresh() }
    }

    @ViewBuilder
    private var normalContent: some View {
        @Bindable var binding = windowState

        NavigationSplitView {
            Sidebar(selection: $binding.section)
        } detail: {
            detail(for: windowState.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.leafBackground.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        StatusPill()
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 920, minHeight: 620)
        .onAppear { reader.refresh() }
    }

    @ViewBuilder
    private func detail(for section: WindowSection) -> some View {
        switch section {
        case .home:         HomeView()
        case .activity:     ActivityView()
        case .team:         TeamView()
        case .connections:  ConnectionsView()
        case .organization: OrganizationView()
        case .settings:     WindowSettingsView()
        case .profile:      ProfileView()
        }
    }
}
