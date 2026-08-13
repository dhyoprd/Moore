// Ticket #33 — navigation shell: the four bottom tabs (screen blueprint #7),
// Active Workout reserved as a full-screen cover (non-dismissable; only the
// minimize chevron collapses it to the mini-player), and the persistent
// mini-player bar above the tab bar while a session is live.

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        switch appState.phase {
        case .failed(let failure):
            FatalBootView(failure: failure)
        case .ready:
            ZStack(alignment: .bottom) {
                TabView(selection: $appState.selectedTab) {
                    HomeView()
                        .tabItem { Label(AppTab.home.title, systemImage: "house.fill") }
                        .tag(AppTab.home)
                    HistoryView()
                        .tabItem { Label(AppTab.history.title, systemImage: "clock.fill") }
                        .tag(AppTab.history)
                    AnalyticsView()
                        .tabItem { Label(AppTab.analytics.title, systemImage: "chart.line.uptrend.xyaxis") }
                        .tag(AppTab.analytics)
                    SettingsView()
                        .tabItem { Label(AppTab.settings.title, systemImage: "gearshape.fill") }
                        .tag(AppTab.settings)
                }

                // Persistent mini-player bar (#7 §2): screen-independent, survives
                // tab switches; one tap re-presents the Active Workout modal.
                // Hidden while the modal itself is presented.
                if let session = appState.activeSession, appState.presentedWorkout == nil {
                    MiniPlayerView(session: session) {
                        appState.presentWorkout(sessionId: session.id)
                    }
                    .padding(.horizontal, DesignTokens.Spacing.l)
                    .padding(.bottom, 56)   // sits above the tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Active Workout — full-screen modal OVER the tab bar (#7 §2).
            // #33 ships the presentation hook + stub content; the money screen is #34.
            .fullScreenCover(item: $appState.presentedWorkout) { presentation in
                ActiveWorkoutStubView(sessionId: presentation.id)
            }
            .animation(.spring(duration: DesignTokens.Motion.expandSeconds), value: appState.activeSession?.id)
        }
    }
}

// MARK: - Fatal recovery (SC-foundation §6 copy)

/// Boot failed: storage unavailable or migration chain failure. Copy-driven per
/// SC-foundation §6; the technical detail rides small underneath for support.
struct FatalBootView: View {
    let failure: BootFailure

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(MooreColor.lime)
            Text(failure.isMigrationFailure ? UICopy.dbMigrationFailedTitle : UICopy.dbFatalTitle)
                .font(MooreFont.display(.title2))
                .foregroundStyle(MooreColor.textPrimary)
            Text(failure.isMigrationFailure ? UICopy.dbMigrationFailedBody : UICopy.dbFatalBody)
                .font(MooreFont.body())
                .foregroundStyle(MooreColor.textSecondary)
                .multilineTextAlignment(.center)
            Text(failure.detail)
                .font(MooreFont.numeric(.caption2))
                .foregroundStyle(MooreColor.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(DesignTokens.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MooreColor.steelBase)
    }
}
