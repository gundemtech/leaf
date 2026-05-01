import SwiftUI

struct WindowSettingsView: View {
    @Environment(LaunchAgentService.self) private var launchAgent
    @Environment(WatchedFoldersService.self) private var watchedFolders
    @Environment(UpdaterController.self) private var updater

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SETTINGS")
                        .leafLabelStyle()
                    Text("Settings")
                        .font(.leafHeadline)
                        .foregroundStyle(.leafInk)
                }
                .padding(.bottom, 4)

                GeneralSettingsSection(launchAgent: launchAgent, updater: updater)

                FoldersSettings(service: watchedFolders)

                PrivacySettingsSection()
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
