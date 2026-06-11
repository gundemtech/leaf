//
//  NowHeroBlock.swift
//  Home redesign — single top-of-Home anchor card. Merges the former
//  ResumeHeroBlock (where-stopped excerpt + CTAs) and YoureOnBlock (task ·
//  session · files): both degraded into the same "branch · +N ahead" text
//  whenever whereStopped / linearID were absent, so Home opened on two
//  near-identical cards. Line composition is NowHeroComposer (LeafCore,
//  tested); this body is a thin shell plus the CTA gating that needs AppKit.
//
//    [Resume]            Re-foregrounds the anchor app (NSWorkspace).
//    [Linear LEAF-NN]    Opens the Linear issue in the default browser.
//    [Diff with main]    Opens the GitHub compare URL (feature branches).
//
//  The YOU·NOW state badge lives in this card's header row now (was at the
//  foot of TODAY) — current state belongs next to current work.
//

import AppKit
import LeafCore
import SwiftUI

struct NowHeroBlock: View {
    let snapshot: WhereStoppedSnapshot?
    let gitDelta: GitDeltaSnapshot?
    let taskIdentity: TaskIdentity?
    let session: CurrentTaskSession?
    let youNowState: YouNowState

    @Environment(RouteCoordinator.self) private var coordinator
    @Environment(\.calendar) private var calendar
    @StateObject private var localAppsStore = LocalAppsStore()

    private var hero: NowHeroPresentation {
        NowHeroComposer.compose(
            taskIdentity: taskIdentity, gitDelta: gitDelta, session: session,
            whereStopped: snapshot, now: Date(), calendar: calendar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text(headerText)
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
                .accessibilityAddTraits(.isHeader)

            LeafCard(padding: .regular) {
                cardContent
            }
            .animation(.easeInOut(duration: 0.25), value: snapshot)
            .animation(.easeInOut(duration: 0.25), value: gitDelta)
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        let hero = self.hero
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: LeafSpace.sm) {
                if let taskLine = hero.taskLine {
                    Text(taskLine)
                        .font(LeafType.title.small)
                        .foregroundStyle(LeafColor.text.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                YouNowStateBadge(state: youNowState)
            }
            if hero.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    if let sessionLine = hero.sessionLine {
                        secondaryLine(sessionLine)
                    }
                    if let anchorLine = hero.anchorLine {
                        secondaryLine(anchorLine)
                    }
                    if let commitLine = hero.commitLine {
                        secondaryLine(commitLine)
                    }
                    if let filesLine = hero.filesLine {
                        secondaryLine(filesLine)
                    }
                    if let wipLine = hero.wipLine {
                        secondaryLine(wipLine)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if hasAnyCTA {
                ctaRow
                    .padding(.top, LeafSpace.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func secondaryLine(_ text: String) -> some View {
        Text(text)
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var emptyState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "No recent work captured",
            description: "Open an IDE or pin a Linear issue to populate this card."
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - CTAs (gating preserved from the former ResumeHeroBlock)

    private var hasAnyCTA: Bool {
        resumeBundleID != nil || linearURL != nil || diffURL != nil
    }

    @ViewBuilder
    private var ctaRow: some View {
        HStack(spacing: LeafSpace.sm) {
            if let bundleID = resumeBundleID {
                Button("Resume") { resume(bundleID: bundleID) }
                    .accessibilityHint("Re-foregrounds the last anchor app.")
            }
            if let url = linearURL, let linearID = taskIdentity?.linearID {
                Button("Linear \(linearID)") { coordinator.openExternalURL(url) }
                    .accessibilityHint("Opens \(linearID) in Linear.")
            }
            if let url = diffURL {
                Button("Diff with main") { coordinator.openExternalURL(url) }
                    .accessibilityHint("Opens GitHub compare view for current branch.")
            }
        }
        .buttonStyle(.borderless)
    }

    /// Gate: anchor bundleID known + enabled in LocalAppsStore + app installed.
    private var resumeBundleID: String? {
        guard let bundleID = snapshot?.anchorBundleID,
            localAppsStore.isEnabled(bundleID),
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        else { return nil }
        return bundleID
    }

    private func resume(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Gate: taskIdentity.linearID + linearWorkspaceSlug. Hidden when slug is nil
    /// (no presence_state.linear row yet — pre-OAuth or freshly installed).
    private var linearURL: URL? {
        guard let linearID = taskIdentity?.linearID,
            let slug = taskIdentity?.linearWorkspaceSlug, !slug.isEmpty
        else { return nil }
        return URL(string: "https://linear.app/\(slug)/issue/\(linearID)")
    }

    /// Gate: GitHub remote + non-trunk branch + mergeBase known. Trunk checkouts
    /// hide the compare CTA for the same reason the WIP line hides ahead/behind —
    /// trunk-vs-release-tag comparison is repo topology, not the user's work.
    private var diffURL: URL? {
        guard let remote = gitDelta?.remote,
            remote.host == "github.com",
            let branch = taskIdentity?.branch,
            let mergeBaseRef = gitDelta?.mergeBase
        else { return nil }
        let baseRef = YoureOnRowComposer.refBasename(mergeBaseRef)
        guard !NowHeroComposer.isTrunk(branch: branch, mergeBaseBasename: baseRef) else {
            return nil
        }
        let encodedBase = baseRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? baseRef
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? branch
        return URL(
            string:
                "https://github.com/\(remote.owner)/\(remote.repo)/compare/\(encodedBase)...\(encodedBranch)"
        )
    }

    // MARK: - Header

    private var headerText: String {
        guard let snap = snapshot, !snap.excerpt.isEmpty else { return "NOW" }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let delta = max(0, nowMs - snap.generatedAtMs)
        return "NOW · picked up \(HomeRelativeTimeFormatter.format(deltaMs: delta, nowMs: nowMs))"
    }
}
