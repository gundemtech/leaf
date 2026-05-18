//
//  GoogleCalendarSurfaceCardViewModel.swift
//  Track 7 P2 — pure mapper from (GoogleCalendarOAuthService,
//  InsightsSnapshot?) → SurfaceCardState<GoogleCalendarCardPayload>.
//  Namespace enum (stateless); SwiftUI tracks oauth state via
//  @Observable and the snapshot via the parameter.
//
//  Enable signal mirrors SurfacesSection.isEnabled exactly: connected
//  case only. "Captured · Waiting for events" copy lives in the wrapper
//  view's .enabledZeroToday branch (per spec §3.5), not here.
//

import Foundation
import LeafCore

enum GoogleCalendarSurfaceCardViewModel {
    static func state(
        calendarOAuth: GoogleCalendarOAuthService,
        snapshot: InsightsSnapshot?
    ) -> SurfaceCardState<GoogleCalendarCardPayload> {
        guard case .connected = calendarOAuth.state else {
            return .disabled
        }
        guard let snapshot else {
            return .enabledLoading
        }
        guard let activity = snapshot.googleCalendarActivity else {
            return .enabledZeroToday
        }
        if activity.focusBlockCount == 0
            && activity.oooBlockCount == 0
            && activity.workingLocationCount == 0
        {
            return .enabledZeroToday
        }
        let payload = GoogleCalendarCardPayload(
            focusBlockCount: activity.focusBlockCount,
            focusDurationSeconds: activity.focusDurationSeconds,
            oooBlockCount: activity.oooBlockCount,
            workingLocationCount: activity.workingLocationCount,
            dailyFocusMinutes: activity.dailyFocusMinutes
        )
        return .enabledPopulated(payload: payload)
    }
}
