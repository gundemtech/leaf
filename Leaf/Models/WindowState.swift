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

    var icon: String {
        switch self {
        case .home:         "chart.bar.xaxis"
        case .activity:     "list.bullet.rectangle"
        case .team:         "person.2"
        case .connections:  "link"
        case .organization: "building.2"
        case .settings:     "gearshape"
        case .profile:      "person.crop.circle"
        }
    }
}

@MainActor
@Observable
final class WindowState {
    var section: WindowSection = .home
}
