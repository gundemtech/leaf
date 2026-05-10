import SwiftUI

struct Sidebar: View {
    @Binding var selection: WindowSection

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(WindowSection.allCases) { section in
                    SidebarRow(section: section, isSelected: section == selection)
                        .tag(section)
                }
            } header: {
                Text("Leaf")
                    .leafLabelStyle()
                    .padding(.bottom, 6)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }
}

private struct SidebarRow: View {
    let section: WindowSection
    let isSelected: Bool

    var body: some View {
        Label {
            Text(section.title)
                .font(.leafBody)
                .foregroundStyle(isSelected ? .leafInk : Color.leafInk.opacity(0.85))
        } icon: {
            Group {
                if section.iconIsSystem {
                    Image(systemName: section.icon)
                } else {
                    Image.leafAsset(section.icon).frame(width: 16, height: 16)
                }
            }
            .foregroundStyle(isSelected ? .leafAccentDeep : .leafMuted)
        }
        .padding(.vertical, 2)
    }
}
