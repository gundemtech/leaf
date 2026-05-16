//
//  BrowserAllowListSection.swift
//  Leaf
//
//  Phase Track-6 P3 — Settings → Browser Allow-list. Domains listed here
//  capture full URLs or URL+path when visited; all other domains get only
//  the domain name (domainOnly — the privacy-first default).
//
//  Pattern mirrors FoldersSettings: LeafSection with cta slot, LeafCard
//  with per-row rows separated by LeafDivider, "Add Domain" → sheet.
//

import SwiftUI
import LeafCore

struct BrowserAllowListSection: View {
    @Bindable var store: BrowserAllowListStore

    @State private var showingAddSheet = false

    var body: some View {
        LeafSection(
            title: "Browser Allow-list",
            description: "Domains added here capture full URLs and page titles when you visit them. All other domains record only the domain name."
        ) {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                if store.entries.isEmpty {
                    LeafEmptyState(
                        icon: LeafIcons.object.appPlaceholder,
                        title: "No domains added",
                        description: "Add a domain to capture full URLs when you visit it."
                    )
                } else {
                    LeafCard(variant: .raised, padding: .tight) {
                        VStack(spacing: 0) {
                            let entries = store.entries
                            ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                                domainRow(entry)
                                if idx < entries.count - 1 {
                                    LeafDivider()
                                }
                            }
                        }
                    }
                }

                if let error = store.lastErrorMessage {
                    LeafBanner(tone: .danger, title: "Error", description: error)
                }
            }
        } cta: {
            LeafButton(
                "Add Domain…",
                variant: .secondary,
                size: .sm,
                icon: .asset(LeafIcons.action.add),
                action: { showingAddSheet = true }
            )
        }
        .onAppear { store.load() }
        .sheet(isPresented: $showingAddSheet) {
            AddBrowserDomainSheet(store: store)
        }
    }

    private func domainRow(_ entry: BrowserDomainAllowEntry) -> some View {
        HStack(alignment: .center, spacing: LeafSpace.md) {
            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                Text(entry.domain)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let notes = entry.notes, !notes.isEmpty {
                    Text(notes)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: LeafSpace.md)
            granularityBadge(entry.granularity)
            LeafIconButton(
                asset: LeafIcons.object.trash,
                variant: .ghost,
                size: .md,
                action: { store.remove(domain: entry.domain) }
            )
        }
        .padding(.horizontal, LeafSpace.md)
        .padding(.vertical, LeafSpace.md)
    }

    @ViewBuilder
    private func granularityBadge(_ gran: URLGranularity) -> some View {
        Text(gran.shortLabel)
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.secondary)
            .padding(.horizontal, LeafSpace.sm)
            .padding(.vertical, LeafSpace.xs)
            .background(
                RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                    .fill(LeafColor.surface.inset)
            )
    }
}

// MARK: - Add Domain Sheet

private struct AddBrowserDomainSheet: View {
    let store: BrowserAllowListStore

    @Environment(\.dismiss) private var dismiss

    @State private var domain: String = ""
    @State private var granularity: URLGranularity = .fullUrl
    @State private var notes: String = ""

    private var isValid: Bool {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !trimmed.isEmpty && !trimmed.contains("/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            Text("Add Domain")
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text("Domain")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                TextField("e.g. github.com", text: $domain)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Text("Enter the eTLD+1 domain without scheme or path.")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }

            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text("URL capture level")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                Picker("Granularity", selection: $granularity) {
                    Text("Full URL").tag(URLGranularity.fullUrl)
                    Text("URL + path (no query)").tag(URLGranularity.pathStripped)
                    Text("Domain only").tag(URLGranularity.domainOnly)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text(granularity.explainer)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }

            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text("Notes (optional)")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                TextField("e.g. Work code review", text: $notes)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: LeafSpace.md) {
                LeafButton("Cancel", variant: .secondary, size: .md) {
                    dismiss()
                }
                LeafButton("Add", variant: .primary, size: .md) {
                    let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let notesValue = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.add(
                        domain: trimmed,
                        granularity: granularity,
                        notes: notesValue.isEmpty ? nil : notesValue
                    )
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .padding(LeafSpace.xxl)
        .frame(minWidth: 380, maxWidth: 480)
    }
}

// MARK: - URLGranularity UI helpers

private extension URLGranularity {
    var shortLabel: String {
        switch self {
        case .fullUrl:       return "Full URL"
        case .pathStripped:  return "URL + path"
        case .domainOnly:    return "Domain only"
        }
    }

    var explainer: String {
        switch self {
        case .fullUrl:
            return "Captures the complete URL including query parameters."
        case .pathStripped:
            return "Captures scheme + host + path only — no query or fragment."
        case .domainOnly:
            return "Captures only the domain name (same as default for all sites)."
        }
    }
}

