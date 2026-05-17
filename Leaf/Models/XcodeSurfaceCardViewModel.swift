//
//  XcodeSurfaceCardViewModel.swift
//  Track 7 P2 — pure mapper from (LocalAppsStore, InsightsSnapshot?) →
//  SurfaceCardState<XcodeCardPayload>. Namespace enum (not a class)
//  because the mapping is stateless. SurfacesSection re-invokes per
//  body pass; SwiftUI tracks LocalAppsStore via @Observable and the
//  snapshot via the parameter, so re-evaluation is automatic.
//
//  Enable signal mirrors SurfacesSection.isEnabled exactly.
//

import Foundation
import LeafCore

enum XcodeSurfaceCardViewModel {
    static func state(
        localAppsStore: LocalAppsStore,
        snapshot: InsightsSnapshot?
    ) -> SurfaceCardState<XcodeCardPayload> {
        guard localAppsStore.isEnabled(Self.bundleID) else {
            return .disabled
        }
        guard let snapshot else {
            return .enabledLoading
        }
        guard let activity = snapshot.xcodeActivity else {
            return .enabledZeroToday
        }
        if activity.buildCount == 0 && activity.testRunCount == 0 {
            return .enabledZeroToday
        }
        let payload = XcodeCardPayload(
            buildCount: activity.buildCount,
            testRunCount: activity.testRunCount,
            buildSuccessCount: activity.buildSuccessCount,
            buildFailureCount: activity.buildFailureCount,
            schemesTouchedCount: activity.topSchemes.count,
            dailyBuilds: activity.dailyBuilds
        )
        return .enabledPopulated(payload: payload)
    }

    static let bundleID = "com.apple.dt.Xcode"
}
