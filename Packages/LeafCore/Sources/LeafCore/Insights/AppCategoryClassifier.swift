//
//  AppCategoryClassifier.swift
//  LeafCore
//
//  Phase 4.10.B — public taxonomy + injection seam.
//
//  `AppCategory` enum — public-safe taxonomy for UI dot colors and granularity
//  policy decisions. The concrete preset bundle ID list is implementation moat,
//  living in `LeafCorePrivate/Prod/Insights/ProdAppCategoryClassifier.swift`
//  (gitignored). Public LeafCore ships `EmptyAppCategoryClassifier` for
//  tests / iOS-future / open-source consumers — everything is classified as
//  `.other`. App targets inject `ProdAppCategoryClassifier()` explicitly via the
//  composition root.
//

import Foundation

public enum AppCategory: String, Sendable, Hashable, CaseIterable {
    case dev
    case browse
    case communication
    case design
    case other
}

public protocol AppCategoryClassifier: Sendable {
    func category(for bundleID: String) -> AppCategory
}

/// Default classifier — everything maps to `.other`. Used when the
/// composition root did not inject the moat impl (tests, iOS-future,
/// open-source clone).
public struct EmptyAppCategoryClassifier: AppCategoryClassifier {
    public init() {}
    public func category(for bundleID: String) -> AppCategory { .other }
}
