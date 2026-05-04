import SwiftUI

struct RootView: View {
    @Environment(WindowState.self) private var windowState
    @Environment(InsightsReader.self) private var reader

    var body: some View {
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
