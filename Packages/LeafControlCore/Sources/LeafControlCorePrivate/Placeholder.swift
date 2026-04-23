// LeafControlCorePrivate — moat-target.
//
// Этот файл (Placeholder.swift) — единственный TRACKED в git. Он держит
// SPM-target «живым» на публичных клонах (target без source-файлов = SPM resolve fail).
//
// Реальные реализации (SQL-тела Insights, точные пороги, SQLCipher pragma values,
// crypto envelope internals) живут в поддиректориях `Insights/`, `Config/`, `Crypto/`
// рядом с этим файлом — они в `.gitignore`, существуют только на dev-машине.
//
// Phase 0: здесь ничего не делается. Пустой namespace чтобы было что компилировать.
// Phase 1: добавятся типы-реализации (RealTimeInApp, Thresholds и т.д.),
// которые public `LeafControlCore` будет звать через dependency injection.

import Foundation

enum LeafControlCorePrivatePlaceholder {
    static let buildTag = "placeholder"
}
