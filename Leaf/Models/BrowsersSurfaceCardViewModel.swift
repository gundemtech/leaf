//
//  BrowsersSurfaceCardViewModel.swift
//  Track 7 P2 — pure mapper from (LocalAppsStore, BrowserAllowListStore,
//  InsightsSnapshot?) → SurfaceCardState<BrowsersCardPayload>.
//  Namespace enum (stateless); SwiftUI tracks LocalAppsStore + the
//  allow-list store via @Observable, and the snapshot via the parameter.
//
//  Enable signal mirrors SurfacesSection.isEnabled exactly.
//

import Foundation
import LeafCore

enum BrowsersSurfaceCardViewModel {
    static func state(
        localAppsStore: LocalAppsStore,
        browserAllowList: BrowserAllowListStore,
        snapshot: InsightsSnapshot?
    ) -> SurfaceCardState<BrowsersCardPayload> {
        let enabled =
            !browserAllowList.entries.isEmpty
            || localAppsStore.browserBookmarksChromeEnabled
            || localAppsStore.browserBookmarksSafariEnabled
        guard enabled else {
            return .disabled
        }
        guard let snapshot else {
            return .enabledLoading
        }
        guard let activity = snapshot.browsersActivity else {
            return .enabledZeroToday
        }
        if activity.pageCount == 0 {
            return .enabledZeroToday
        }
        let payload = BrowsersCardPayload(
            pageCount: activity.pageCount,
            domainCount: activity.domainCount,
            safariCount: activity.safariPageCount,
            chromeCount: activity.chromePageCount,
            arcCount: activity.arcPageCount,
            bookmarksAddedCount: activity.bookmarkEventCount,
            dailyNavigations: activity.dailyNavigations
        )
        return .enabledPopulated(payload: payload)
    }
}
