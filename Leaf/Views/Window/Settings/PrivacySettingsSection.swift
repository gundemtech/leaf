import SwiftUI

struct PrivacySettingsSection: View {
    var body: some View {
        Form {
            Section {
                Text("Phase 1 uses a hardcoded minimal blocklist (Leaf's own processes + system UI).")
                    .foregroundStyle(.secondary)
                Text("Editable per-app Share Controls land in Phase 2.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
    }
}
