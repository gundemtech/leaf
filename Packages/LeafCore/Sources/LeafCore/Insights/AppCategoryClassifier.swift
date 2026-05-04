//
//  AppCategoryClassifier.swift
//  LeafCore
//
//  Phase 4.10.B — public taxonomy + injection seam.
//
//  `AppCategory` enum — public-safe taxonomy для UI dot colors и granularity
//  policy decisions. Конкретный preset bundle ID list — implementation moat,
//  живёт в `LeafCorePrivate/Prod/Insights/ProdAppCategoryClassifier.swift`
//  (gitignored). Public LeafCore поставляет `EmptyAppCategoryClassifier` для
//  тестов / iOS-future / open-source консьюмеров — всё классифицируется как
//  `.other`. App targets прокидывают `ProdAppCategoryClassifier()` явно через
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

/// Default classifier — everything maps to `.other`. Используется когда
/// composition root не пробросил moat'овый импл (тесты, iOS-future,
/// open-source клон).
public struct EmptyAppCategoryClassifier: AppCategoryClassifier {
    public init() {}
    public func category(for bundleID: String) -> AppCategory { .other }
}
