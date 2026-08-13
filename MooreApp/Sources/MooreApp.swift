// Ticket #33 — app entry. Boots the composition root synchronously (first boot
// applies the full migration chain before the first frame), then hands the
// Observable AppState to the SwiftUI environment. Views stay thin: layout +
// binding to the Foundation-only models.

import SwiftUI

@main
struct MooreApp: App {
    /// One synchronous boot: GRDB open → canonical migration chain → seed →
    /// DAO/view-model wiring (AppDependencies). Failures surface as the
    /// SC-foundation §6 fatal-recovery screen via AppState.phase.
    @State private var appState = AppState.boot()

    init() {
        // #40: system-bar chrome (SC-visual-system Tier 1 shell) — UIKit
        // appearance, configured once before the first frame.
        MooreAppearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)   // steel-dark register (SC-visual-system)
                .tint(MooreColor.lime)         // lime.vivid affordance tint
        }
    }
}
