//
//  SettingsView.swift
//  LeafControl
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 320)
    }
}

private struct GeneralSettings: View {
    var body: some View {
        Form {
            Section {
                Text("Background collection toggle lands in Phase 1.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Collection")
            }

            Section {
                Text("Share Controls UI lands in Phase 2.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
    }
}
