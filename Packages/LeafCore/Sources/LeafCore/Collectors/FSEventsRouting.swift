import Foundation

/// Phase 2.4 — strategy для перевода raw FSEvents (path + flag bitmask) в
/// `RawEvent` для записи в `events`. Реализация ignore-list, L4/L5 mapping,
/// coalesce dedup — moat (`FSEventsRouterProd`); public side только знает
/// контракт + Stub.
///
/// `async` — Prod использует mutable coalesce state (LRU мапа `[String: Date]`
/// per-actor), и реализуется как actor. Stub возвращает синхронно через async-no-op.
public protocol FSEventsRouting: Sendable {
    func route(
        path: String,
        flags: UInt32,
        watchedFolders: [WatchedFolder],
        now: Date
    ) async -> FSEventsRouteResult
}

/// Результат маршрутизации одного FSEvents callback path.
public enum FSEventsRouteResult: Sendable {
    /// Pass-through в EventWriter — будет записан в `events`.
    case event(RawEvent)
    /// Filtered — известная причина (ignore-list match, coalesce, granularity stripped).
    /// Логируется на уровне `debug`, не warning.
    case filtered(reason: String)
    /// Unknown flag bitmask — нет explicit mapping для этой комбинации FSEvent flags.
    /// Skip silent (не считается ошибкой, FSEvents flags расширяются между macOS-версиями).
    case unknown
}

/// Default-flow stub для CI и dev-без-moat сборок: всегда `.filtered`.
/// FSEventsCollector будет работать (callback пишет/читает), но events
/// не пишутся. Это удобно для testов lifecycle без moat-зависимости.
public struct StubFSEventsRouter: FSEventsRouting {
    public init() {}

    public func route(
        path: String,
        flags: UInt32,
        watchedFolders: [WatchedFolder],
        now: Date
    ) async -> FSEventsRouteResult {
        .filtered(reason: "stub")
    }
}
