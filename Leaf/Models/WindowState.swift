import Foundation
import Observation
import SwiftUI

enum WindowSection: String, CaseIterable, Hashable, Codable, Identifiable {
    case home, activity, team, connections, settings, profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:         "Home"
        case .activity:     "Activity"
        case .team:         "Team"
        case .connections:  "Connections"
        case .settings:     "Settings"
        case .profile:      "Profile"
        }
    }

    /// Asset Catalog name (Figma SVG, template-rendered) for sections with
    /// a custom glyph. All nav sections use Asset Catalog icons.
    var icon: String {
        switch self {
        case .home:         LeafIcons.nav.home
        case .activity:     LeafIcons.nav.activity
        case .team:         LeafIcons.nav.team
        case .connections:  LeafIcons.nav.connections
        case .settings:     LeafIcons.nav.settings
        case .profile:      LeafIcons.nav.profile
        }
    }

    /// True when `icon` is an SF Symbol (system rendering); false when it
    /// is an Asset Catalog name (template-rendered). All current sections
    /// use Asset Catalog icons — SF Symbol rendering is no longer needed.
    var iconIsSystem: Bool { false }
}

@MainActor
@Observable
final class WindowState {
    var section: WindowSection = .home
}
