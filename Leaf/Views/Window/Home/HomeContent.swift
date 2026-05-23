//
//  HomeContent.swift
//  Track-10 T7 — extracted from HomeView.swift to defend the HomeView LOC
//  budget (master spec §7.2 gate 6 ≤ 310) before the Zone-4 ViewThatFits
//  2-col rewire lands in C5. Zero behavior change in this commit.
//
//  Track-8 5-block composition (post Track-10 T2/T3/T4/T5/T6/T7):
//    1. RESUME HERO                              (T2)
//    2. TODAY (with inline YOU·NOW state badge)  (T3)
//    3. NEEDS YOU ‖ TEAM·N  (ViewThatFits 2-col) (T4, T6)
//    4. SINCE ‖ YOU'RE ON   (ViewThatFits 2-col) (T5, T7)
//

import LeafCore
import SwiftUI

struct HomeContent: View {
    let snapshot: InsightsSnapshot
    @Environment(RouteCoordinator.self) private var coordinator
    @Environment(InsightsReader.self) private var reader
    @Environment(LastSeenCursor.self) private var lastSeenCursor

    var body: some View {
        @Bindable var coord = coordinator
        NavigationStack(path: $coord.homePath) {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                // Track-10 T2 — RESUME hero promoted to top of Home. Replaces
                // the Track-9 T7 bottom WhereStoppedBlock (deleted in T2).
                ResumeHeroBlock(
                    snapshot: snapshot.whereStopped,
                    gitDelta: snapshot.gitDelta,
                    taskIdentity: snapshot.currentTaskIdentity
                )

                TodayBlock(
                    metrics: snapshot.todayMetrics,
                    youNowState: snapshot.youNowState
                )

                // Track-10 T6 — Zone-3 solo-vs-team gate. Solo Mac (no org or
                // 1-member personal org) → NEEDS YOU stays full-width and the
                // narrow Phase 8.5 WithYouOnThisBlock disappears. Team install
                // (memberCount > 1) → 2-col ViewThatFits side-by-side; narrow
                // window collapses to stacked NEEDS YOU above TEAM·N. Reader
                // stub returns []; TeamNBlock renders empty CTA until
                // Phase 5.4 lights up DBTeammatePresenceReader.
                if snapshot.memberCount > 1 {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: LeafSpace.md) {
                            NeedsYouBlock(items: snapshot.inboxItems)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            TeamNBlock(teammates: snapshot.activeTeammates)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        VStack(alignment: .leading, spacing: LeafSpace.xl) {
                            NeedsYouBlock(items: snapshot.inboxItems)
                            TeamNBlock(teammates: snapshot.activeTeammates)
                        }
                    }
                } else {
                    NeedsYouBlock(items: snapshot.inboxItems)
                }

                // Track-10 T7 — Zone-4 ViewThatFits 2-col `SINCE ‖ YOU'RE ON`
                // per master spec §2 scope lock #5. T6 ViewThatFits Zone-3
                // precedent reuse: wide window → HStack 2-col; narrow →
                // VStack stacked, SINCE above YOU'RE ON (priority order
                // baked into the VStack child sequence).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: LeafSpace.md) {
                        SinceLastActiveBlock(
                            items: snapshot.sinceLastActiveItems,
                            onMarkAllAsSeen: {
                                lastSeenCursor.markAllAsSeen(now: Date())
                                reader.refresh()
                            }
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        YoureOnBlock(
                            session: snapshot.currentSession,
                            gitDelta: snapshot.gitDelta
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    VStack(alignment: .leading, spacing: LeafSpace.xl) {
                        SinceLastActiveBlock(
                            items: snapshot.sinceLastActiveItems,
                            onMarkAllAsSeen: {
                                lastSeenCursor.markAllAsSeen(now: Date())
                                reader.refresh()
                            }
                        )
                        YoureOnBlock(
                            session: snapshot.currentSession,
                            gitDelta: snapshot.gitDelta
                        )
                    }
                }
            }
            .navigationDestination(for: HomeSurface.self) { surface in
                detail(for: surface)
            }
            .navigationDestination(for: WorkStateRoute.self) { _ in
                WorkStateDetailScreen()
            }
            .navigationDestination(for: LayerBProvider.self) { provider in
                layerBDetail(for: provider)
            }
        }
    }

    @ViewBuilder
    private func detail(for surface: HomeSurface) -> some View {
        switch surface {
        case .claudeCode:
            ClaudeCodeDetailScreen()
        case .xcode:
            XcodeDetailScreen()
        case .ides:
            IDEsDetailScreen()
        case .browsers:
            BrowsersDetailScreen()
        case .zoom:
            ZoomDetailScreen()
        case .calendar:
            GoogleCalendarDetailScreen()
        }
    }

    @ViewBuilder
    private func layerBDetail(for provider: LayerBProvider) -> some View {
        switch provider {
        case .linear:
            LinearDetailScreen()
        case .github:
            GitHubDetailScreen()
        case .slack:
            SlackDetailScreen()
        }
    }
}
