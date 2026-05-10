import Foundation
import Observation
import SwiftUI

enum WindowSection: String, CaseIterable, Hashable, Codable, Identifiable {
    case home, activity, team, connections, organization, settings, profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:         "Home"
        case .activity:     "Activity"
        case .team:         "Team"
        case .connections:  "Connections"
        case .organization: "Organization"
        case .settings:     "Settings"
        case .profile:      "Profile"
        }
    }

    /// Asset Catalog name (Figma SVG, template-rendered) for sections with
    /// a custom glyph; SF Symbol name for `.organization` (no custom glyph
    /// shipped — section будет удалена когда UX уйдёт на single-team модель).
    var icon: String {
        switch self {
        case .home:         LeafIcons.nav.home
        case .activity:     LeafIcons.nav.activity
        case .team:         LeafIcons.nav.team
        case .connections:  LeafIcons.nav.connections
        case .organization: LeafIcons.nav.organizationSF
        case .settings:     LeafIcons.nav.settings
        case .profile:      LeafIcons.nav.profile
        }
    }

    /// True when `icon` is an SF Symbol (system rendering); false when it
    /// is an Asset Catalog name (template-rendered).
    var iconIsSystem: Bool {
        if case .organization = self { return true }
        return false
    }
}

@MainActor
@Observable
final class WindowState {
    var section: WindowSection = .home
}
