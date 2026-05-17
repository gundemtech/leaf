//  DetailHeadline.swift
//  Track 7 P4 — promoted to LeafCore so SPM formatters can return it
//  and the app's SurfaceDetailLayout can reference it via import LeafCore.
//  Previously declared locally in SurfaceDetailLayout.swift (app target).

/// Value/trend pair driving the headline block in every SurfaceDetailLayout.
public struct DetailHeadline: Equatable, Sendable {
    public let value: String
    /// Optional trend annotation rendered below the value. Nil → row hidden.
    public let trend: String?

    public init(value: String, trend: String?) {
        self.value = value
        self.trend = trend
    }
}
