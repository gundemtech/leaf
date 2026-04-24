//
//  LeafControlApp.swift
//  LeafControl
//

import SwiftUI
import LeafControlCore
#if LEAFCONTROL_PROD
import LeafControlCorePrivate
#endif

@main
struct LeafControlApp: App {
    @State private var launchAgent = LaunchAgentService()

    init() {
        // Register Derived Insights provider once per app launch. Прямой
        // import + register здесь возможен т.к. app target гарантированно
        // получает флаг LEAFCONTROL_PROD из xcconfig (в отличие от SPM
        // dependencies, куда флаг не пропагируется).
        #if LEAFCONTROL_PROD
        DerivedInsightsFactory.register { LeafControlCorePrivate.ProdInsights(database: $0) }
        #endif
    }

    var body: some Scene {
        MenuBarExtra("LeafControl", systemImage: "leaf") {
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
