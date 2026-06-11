//
//  HomeContent.swift
//  Home redesign — 4-zone composition. The screen answers four questions in
//  ten seconds, top to bottom:
//    1. NOW          — what am I on (merged former RESUME hero + YOU'RE ON)
//    2. TODAY        — how is the day going (+7-day focus sparkline)
//    3. NEEDS YOU ‖ TEAM·N — what waits on me / who's around
//    4. WHILE YOU WERE AWAY — what happened without me (8-row cap)
//    (+ RECAP / EOD standup helpers, hour-gated as before)
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
                NowHeroBlock(
                    snapshot: snapshot.whereStopped,
                    gitDelta: snapshot.gitDelta,
                    taskIdentity: snapshot.currentTaskIdentity,
                    session: snapshot.currentSession,
                    youNowState: snapshot.youNowState,
                    lastCommit: snapshot.recentCommit
                )

                TodayBlock(metrics: snapshot.todayMetrics)

                // UC-2 — "am I quietly stuck" card; renders only when the
                // deriver found something. Sits above NEEDS YOU: a stuck PR
                // of mine outranks somebody else's review ping.
                NudgesBlock(nudges: snapshot.nudges)

                // Solo Mac (no org or 1-member personal org) → NEEDS YOU stays
                // full-width. Team install → 2-col ViewThatFits side-by-side;
                // narrow window collapses to stacked.
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

                SinceLastActiveBlock(
                    items: snapshot.sinceLastActiveItems,
                    onMarkAllAsSeen: {
                        lastSeenCursor.markAllAsSeen(now: Date())
                        reader.refresh()
                    }
                )

                // UC-3 — "what shipped while I was out" counters (self-loading
                // block; refreshes on each Home appearance).
                BriefBlock()

                RecapBlock(snapshot: snapshot.standupRecap?.recap)
                EodBlock(snapshot: snapshot.standupRecap?.eod)
            }
        }
    }
}
