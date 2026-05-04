//
//  ActivitySession.swift
//  LeafCore
//
//  Phase 4.10.B — aggregated work session derived from `attention` events
//  (+ `context` boundary markers) by `SessionFeedMapper`. Покрывает кейс
//  "что я делал в Xcode за последние 3 часа": одна строка = один непрерывный
//  блок работы в (bundle, window/url) с длительностью.
//
//  Поле `bundleID` хранится сырым; UI резолвит human-readable имя через
//  `AppNameResolver` на presentation-слое (тот же паттерн что у
//  `ActivityFeedEntry`). Это держит модель свободной от AppKit.
//

import Foundation

/// Один блок непрерывной работы в одном (приложении, окне/URL).
///
/// Identity = id первого attention-события сессии. Это даёт стабильный ключ для
/// SwiftUI ForEach и простой способ сослаться на raw event для последующих
/// drill-down'ов (если когда-то понадобится).
public struct ActivitySession: Identifiable, Sendable, Hashable {
    /// id первого attention event'а в сессии. Стабильный SwiftUI identity.
    public let id: Int64

    /// Bundle identifier приложения (`com.apple.dt.Xcode`).
    public let bundleID: String

    /// Категория для colored dot в UI (dev/browse/communication/design/other).
    public let category: AppCategory

    /// Подзаголовок строки — заголовок focused window или browser URL.
    /// `nil` когда AX permission не выдан или granularity ceiling = L1.
    public let contextLabel: String?

    /// Начало сессии — timestamp первого attention события.
    public let start: Date

    /// Конец сессии. Семантика зависит от того, как сессия закрылась:
    ///   * закрылась переключением → end = ts следующего event'а (без gap'а).
    ///   * закрылась idle context → end = ts idle event'а.
    ///   * закрылась таймаутом (gap > threshold) → end = `lastEventTs + gap`.
    ///   * trailing (последняя в выборке) → end = `min(lastEventTs + gap, refEnd)`.
    public let end: Date

    /// Сколько raw attention events схлопнулось в эту сессию (poll'ы +
    /// app-switch'и с одинаковым (bundle, contextLabel)).
    public let eventCount: Int

    public init(
        id: Int64,
        bundleID: String,
        category: AppCategory,
        contextLabel: String?,
        start: Date,
        end: Date,
        eventCount: Int
    ) {
        self.id = id
        self.bundleID = bundleID
        self.category = category
        self.contextLabel = contextLabel
        self.start = start
        self.end = end
        self.eventCount = eventCount
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}
