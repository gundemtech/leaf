//
//  LeafApp.swift
//  Leaf
//

import SwiftUI
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

@main
struct LeafApp: App {
    @State private var launchAgent = LaunchAgentService()

    init() {
        // Register Derived Insights provider once per app launch. Прямой
        // import + register здесь возможен т.к. app target гарантированно
        // получает флаг LEAF_PROD из xcconfig (в отличие от SPM
        // dependencies, куда флаг не пропагируется).
        #if LEAF_PROD
        DerivedInsightsFactory.register { LeafCorePrivate.ProdInsights(database: $0) }
        #endif
    }

    var body: some Scene {
        MenuBarExtra("Leaf", systemImage: "leaf") {
            MenuBarContent()
                .environment(launchAgent)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(launchAgent)
        }
    }
}
