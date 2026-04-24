//
//  InsightsReader.swift
//  LeafControl
//
//  @Observable state-machine для MenuBarContent: открывает events.sqlite
//  в reader-режиме, зовёт Derived Insights (timeInApp за "today") и отдаёт
//  результат в UI. Управление параллельными refresh'ами, обработка
//  отсутствующей базы, логирование ошибок через os.Logger.
//

import Foundation
import Observation
import OSLog
import LeafControlCore
#if LEAFCONTROL_PROD
import LeafControlCorePrivate
#endif

// Note: `#if LEAFCONTROL_PROD import LeafControlCorePrivate` остаётся здесь
// чтобы `ProdConfigs.database` резолвился в `defaultConfig()`. Provider
// для insights регистрируется отдельно, в `LeafControlApp.init()`.

@MainActor
@Observable
final class InsightsReader {
    enum State {
        case notConfigured(message: String)
        case loading
        case loaded(entries: [AppTimeEntry], updated: Date)
        case empty(message: String)
        case error(message: String)
    }

    private(set) var state: State = .loading

    private var database: LeafControlCore.Database?
    private var currentTask: Task<Void, Never>?

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let logger = Logger(subsystem: "tech.gundem.leafcontrol.app", category: "insights")

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = InsightsReader.defaultConfig()
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
    }

    func refresh() {
        // Cancel previous refresh'ы — защита от race при быстрых повторных
        // открытиях popover'а (P6 в плане).
        currentTask?.cancel()

        // Pre-check существования файла — избегаем exception overhead и
        // даём осмысленный .notConfigured state вместо обобщённой ошибки (P9).
        if !FileManager.default.fileExists(atPath: databaseURL.path) {
            state = .notConfigured(
                message: "Enable background collection in Settings to see today's activity."
            )
            return
        }

        state = .loading
        let url = databaseURL
        let cfg = databaseConfig
        let cachedDB = database

        currentTask = Task { [self] in
            // Database (@unchecked Sendable) and entries ([AppTimeEntry]) are
            // Sendable, so hopping through MainActor.run after a detached
            // background compute is race-safe.
            let result: Result<(LeafControlCore.Database, [AppTimeEntry]), Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try cachedDB ?? LeafControlCore.Database.openForRead(at: url, config: cfg)
                        let insights = DerivedInsightsFactory.make(database: db)
                        let today = InsightsReader.todayInterval()
                        let entries = try insights.timeInApp(period: today)
                        try Task.checkCancellation()
                        return .success((db, entries))
                    } catch {
                        return .failure(error)
                    }
                }.value

            if Task.isCancelled { return }

            switch result {
            case .success(let (db, entries)):
                self.database = db
                if entries.isEmpty {
                    self.state = .empty(
                        message: "Collecting… activity will appear after a few app switches."
                    )
                } else {
                    self.state = .loaded(entries: entries, updated: Date())
                }
            case .failure(let error):
                if error is CancellationError { return }
                // Детально логируем (os.Logger → Console.app), в UI
                // только generic сообщение (P8 — moat-safe).
                self.logger.error("timeInApp failed: \(String(describing: error), privacy: .public)")
                self.database = nil
                self.state = .error(
                    message: "Couldn't read today's activity. Try Refresh."
                )
            }
        }
    }

    nonisolated private static func todayInterval() -> DateInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date().addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    nonisolated private static func defaultConfig() -> DatabaseConfig {
        #if LEAFCONTROL_PROD
        return ProdConfigs.database
        #else
        return .weakDefaults
        #endif
    }
}
