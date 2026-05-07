//
//  CreateTeamStepView.swift
//  Leaf
//
//  Phase 5.5.B — onboarding `.team` admin path: enter org name + display name → calls
//  OrgReader.createPersonalOrg(displayName:) (org name surfaces в OrgService logic per 5.1.D).
//  На success — caller (OnboardingView) advances to `.done` через .onChange.
//

import SwiftUI
import LeafCore

struct CreateTeamStepView: View {
    @Environment(OrgReader.self) private var orgReader
    @State private var displayName: String = ""
    @State private var submitted: Bool = false
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create new team")
                .font(.subheadline.weight(.semibold))
            Text("Pick how you'll show up to your teammates. You can invite them right after.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR DISPLAY NAME")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. Sasha", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(submitted)
            }

            HStack {
                Button("Back") { onCancel() }
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
                Button("Create") {
                    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    submitted = true
                    orgReader.createPersonalOrg(displayName: trimmed)
                }
                .buttonStyle(.borderedProminent)
                .disabled(submitted || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            if displayName.isEmpty {
                displayName = NSFullUserName()
            }
        }
    }
}
