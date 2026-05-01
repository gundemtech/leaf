import SwiftUI

struct ConnectionsView: View {
    @Environment(LinearOAuthService.self) private var linearOAuth
    @Environment(GitHubOAuthService.self) private var githubOAuth
    @Environment(SlackOAuthService.self) private var slackOAuth

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CONNECTIONS")
                        .leafLabelStyle()
                    Text("Connections")
                        .font(.leafHeadline)
                        .foregroundStyle(.leafInk)
                    Text("Linear, GitHub, Slack — sources of truth Leaf observes on your behalf.")
                        .font(.leafBody)
                        .foregroundStyle(.leafMuted)
                }
                ConnectionsSettings(
                    service: linearOAuth,
                    githubService: githubOAuth,
                    slackService: slackOAuth
                )
                .padding(.top, 8)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
