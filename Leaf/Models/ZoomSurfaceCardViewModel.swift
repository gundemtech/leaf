//
//  ZoomSurfaceCardViewModel.swift
//  Track 7 P2 — pure mapper from (LocalAppsStore, InsightsSnapshot?) →
//  SurfaceCardState<ZoomCardPayload>. Namespace enum (stateless);
//  SurfacesSection re-invokes per body pass.
//
//  Enable signal mirrors SurfacesSection.isEnabled exactly.
//

import Foundation
import LeafCore

enum ZoomSurfaceCardViewModel {
    static func state(
        localAppsStore: LocalAppsStore,
        snapshot: InsightsSnapshot?
    ) -> SurfaceCardState<ZoomCardPayload> {
        guard localAppsStore.isEnabled(Self.bundleID) else {
            return .disabled
        }
        guard let snapshot else {
            return .enabledLoading
        }
        guard let activity = snapshot.zoomActivity else {
            return .enabledZeroToday
        }
        if activity.meetingCount == 0 {
            return .enabledZeroToday
        }
        let payload = ZoomCardPayload(
            meetingCount: activity.meetingCount,
            totalDurationSeconds: activity.totalDurationSeconds,
            calendarLinkedCount: activity.calendarLinkedCount,
            adHocCount: activity.adHocCount,
            dailyMinutes: activity.dailyMinutes
        )
        return .enabledPopulated(payload: payload)
    }

    static let bundleID = "us.zoom.xos"
}
