//
//  YoureOnBlock.swift
//  Track-10 T7 — Zone-4 right-half task session anchor.
//
//  Surfaces "what am I on right now today" — LEAF-ID · branch · +N ahead
//  of merge base · session start clock · per-task focused-min · recent
//  open files. Distinct from RESUME hero (yesterday context) and TODAY
//  with inline state badge (instant lens). Empty state when no active
//  task identifiable. Composition flows through `YoureOnRowComposer`
//  pure helpers (LeafCore-tested).
//
//  Spec: docs/superpowers/specs/2026-05-23-track-10-T7-youre-on-anchor.md §3.4
//

import LeafCore
import SwiftUI

struct YoureOnBlock: View {
    let session: CurrentTaskSession?
    let gitDelta: GitDeltaSnapshot?
    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("YOU'RE ON")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("You're on, task anchor")

            LeafCard(padding: .regular) {
                if let session {
                    populated(session)
                } else {
                    emptyState
                }
            }
        }
    }

    @ViewBuilder
    private func populated(_ session: CurrentTaskSession) -> some View {
        let now = Date()
        let taskLine = YoureOnRowComposer.composeTaskLine(
            session.taskIdentity, gitDelta: gitDelta)
        let sessionLine = YoureOnRowComposer.composeSessionLine(
            sessionStartMs: session.sessionStartMs,
            focusedMin: session.focusedMinSoFar,
            now: now, calendar: calendar)
        let filesLine = YoureOnRowComposer.composeFilesLine(session.openFiles)

        // Two empty-state entrances: outer `session == nil` (handled above)
        // and inner "all three composer lines collapse to nil" (degenerate
        // fixture, not seen in production). Single emptyState codepath.
        if taskLine == nil && sessionLine == nil && filesLine == nil {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                if let taskLine { textLine(taskLine, prominent: true) }
                if let sessionLine { textLine(sessionLine, prominent: false) }
                if let filesLine { textLine(filesLine, prominent: false) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                YoureOnRowComposer.a11yLabel(
                    session.taskIdentity, gitDelta: gitDelta,
                    sessionStartMs: session.sessionStartMs,
                    focusedMin: session.focusedMinSoFar,
                    openFiles: session.openFiles,
                    now: now, calendar: calendar))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "No active task identified.",
            description: "Leaf reads LEAF-XXX from your IDE branch names.",
            style: .compact
        )
    }

    @ViewBuilder
    private func textLine(_ text: String, prominent: Bool) -> some View {
        Text(text)
            .font(LeafType.body.small)
            .foregroundStyle(
                prominent
                    ? LeafColor.text.primary
                    : LeafColor.text.secondary
            )
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
