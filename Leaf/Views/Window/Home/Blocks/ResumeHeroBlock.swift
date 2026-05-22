//
//  ResumeHeroBlock.swift
//  Track-10 T2 — operational hero card at top of Home. Promotes the Track-9 T7
//  small WHERE STOPPED card (Zone 4, easy to skim past) into a high-density
//  resume surface with three CTAs:
//
//    [Resume]                  Re-foregrounds the anchor app (NSWorkspace).
//    [Linear LEAF-NN]          Opens the Linear issue in the default browser.
//    [Diff with main]          Opens the GitHub compare URL.
//
//  Each CTA self-gates on the substrate it needs:
//    Resume         — anchor bundle known + enabled in LocalAppsStore + app installed.
//    Linear         — taskIdentity.linearID + taskIdentity.linearWorkspaceSlug.
//    Diff with main — gitDelta.remote.host == "github.com" + branch + mergeBase.
//
//  The WIP-signal line ("WIP: 3 uncommitted · 4 commits ahead of main") is composed
//  from the same `gitDelta` substrate; absent / all-zero gitDelta hides the line.

import AppKit
import LeafCore
import SwiftUI

struct ResumeHeroBlock: View {
    let snapshot: WhereStoppedSnapshot?
    let gitDelta: GitDeltaSnapshot?
    let taskIdentity: TaskIdentity?

    @Environment(RouteCoordinator.self) private var coordinator
    @StateObject private var localAppsStore = LocalAppsStore()

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text(headerText)
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                cardContent
            }
            .accessibilityElement(children: .combine)
            .animation(.easeInOut(duration: 0.25), value: snapshot)
            .animation(.easeInOut(duration: 0.25), value: gitDelta)
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            if let taskIdentity, !taskIdentity.isEmpty {
                taskLine(taskIdentity)
            }
            if let snap = snapshot, !snap.excerpt.isEmpty {
                anchorLine(snap)
                if let commit = snap.recentLastCommit {
                    Text(commitSubjectLine(commit))
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else if taskIdentity == nil || taskIdentity?.isEmpty == true {
                emptyState
            }
            if let wipText = composeWipLine() {
                Text(wipText)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
            }
            if hasAnyCTA {
                ctaRow
                    .padding(.top, LeafSpace.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Lines

    private func taskLine(_ id: TaskIdentity) -> some View {
        var parts: [String] = []
        if let linearID = id.linearID { parts.append(linearID) }
        if let branch = id.branch { parts.append(branch) }
        return Text(parts.joined(separator: " · "))
            .font(LeafType.title.small)
            .foregroundStyle(LeafColor.text.primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func anchorLine(_ snap: WhereStoppedSnapshot) -> some View {
        Text(lineLabel(for: snap))
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.primary)
            .lineLimit(2)
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

    // MARK: - CTAs

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

    /// Gate: GitHub remote + branch + mergeBase known. Composes
    /// `https://github.com/<owner>/<repo>/compare/<refBasename>...<branch>`.
    private var diffURL: URL? {
        guard let remote = gitDelta?.remote,
            remote.host == "github.com",
            let branch = taskIdentity?.branch,
            let mergeBaseRef = gitDelta?.mergeBase
        else { return nil }
        let baseRef = Self.refBasename(mergeBaseRef)
        let encodedBase = baseRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? baseRef
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? branch
        return URL(
            string:
                "https://github.com/\(remote.owner)/\(remote.repo)/compare/\(encodedBase)...\(encodedBranch)"
        )
    }

    // MARK: - Helpers

    private func composeWipLine() -> String? {
        guard let delta = gitDelta else { return nil }
        var clauses: [String] = []
        if delta.uncommittedCount > 0 {
            clauses.append("\(delta.uncommittedCount) uncommitted")
        }
        if delta.commitsAhead > 0, let ref = delta.mergeBase.map(Self.refBasename) {
            clauses.append("\(delta.commitsAhead) commits ahead of \(ref)")
        }
        if delta.commitsBehind > 0, let ref = delta.mergeBase.map(Self.refBasename) {
            clauses.append("\(delta.commitsBehind) behind")
        }
        return clauses.isEmpty ? nil : "WIP: " + clauses.joined(separator: " · ")
    }

    /// Extracts the trailing path component of a git ref. "origin/main" → "main";
    /// "refs/remotes/origin/main" → "main". Single-segment refs pass through.
    static func refBasename(_ ref: String) -> String {
        ref.split(separator: "/").last.map(String.init) ?? ref
    }

    /// Reuse the existing WhereStoppedBlock line-label heuristic — basename:line
    /// (Xcode anchor), basename (path-only anchor), or excerpt fallback.
    private func lineLabel(for snap: WhereStoppedSnapshot) -> String {
        if let basename = snap.anchorFilePath, !basename.isEmpty {
            if let line = snap.anchorLine, line > 0 {
                return "\(basename):\(line)"
            }
            return basename
        }
        return snap.excerpt
    }

    private func commitSubjectLine(_ commit: RecentCommitSnapshot) -> String {
        let trimmed = commit.subject.trimmingCharacters(in: .whitespaces)
        let capped = trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
        return "Last commit: \"\(capped)\""
    }

    private var headerText: String {
        guard let snap = snapshot, !snap.excerpt.isEmpty else { return "RESUME" }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let delta = max(0, nowMs - snap.generatedAtMs)
        return "RESUME · \(HomeRelativeTimeFormatter.format(deltaMs: delta, nowMs: nowMs))"
    }
}
