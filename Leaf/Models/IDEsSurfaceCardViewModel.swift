//
//  IDEsSurfaceCardViewModel.swift
//  Track 7 P2 — pure mapper from (LocalAppsStore, InsightsSnapshot?) →
//  SurfaceCardState<IDEsCardPayload>. Namespace enum (stateless);
//  SurfacesSection re-invokes per body pass, SwiftUI tracks the store
//  via @Observable and the snapshot via the parameter.
//
//  Enable signal mirrors SurfacesSection.isEnabled exactly.
//

import Foundation
import LeafCore

enum IDEsSurfaceCardViewModel {
    static func state(
        localAppsStore: LocalAppsStore,
        snapshot: InsightsSnapshot?
    ) -> SurfaceCardState<IDEsCardPayload> {
        guard localAppsStore.vscodeStorageEnabled || localAppsStore.jetbrainsStorageEnabled else {
            return .disabled
        }
        guard let snapshot else {
            return .enabledLoading
        }
        guard let activity = snapshot.idesActivity else {
            return .enabledZeroToday
        }
        if activity.totalEventCount == 0 && activity.workspaceCount == 0 {
            return .enabledZeroToday
        }
        let payload = IDEsCardPayload(
            fileEventCount: activity.totalEventCount,
            workspaceCount: activity.workspaceCount,
            vscodeFamilyEventCount: activity.vscodeFamilyEventCount,
            jetbrainsEventCount: activity.jetbrainsEventCount,
            fallbackTitleCount: activity.fallbackTitleCount,
            dailyEvents: activity.dailyEvents
        )
        return .enabledPopulated(payload: payload)
    }
}
