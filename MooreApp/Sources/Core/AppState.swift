// Ticket #33 — app-level state: boot phase, tab selection, Active Workout
// presentation hook, and the Home model. Foundation-only (@Observable from the
// Observation framework — no SwiftUI) so it parses/verifies off-Mac; SwiftUI
// views bind via .environment(AppState.self).
//
// Architecture: ALL business/state logic stays in Foundation-only files (existing
// module view-models are driven, never reimplemented); SwiftUI views stay thin.

import Foundation
import Observation
import MooreRoutines

// MARK: - Tabs (screen blueprint #7: Home, History, Analytics, Settings)

/// The four bottom tabs. Active Workout is deliberately NOT a tab — it is a
/// presented full-screen modal over the tab bar (#7 §2).
public enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case home
    case history
    case analytics
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return UICopy.tabHome
        case .history: return UICopy.tabHistory
        case .analytics: return UICopy.tabAnalytics
        case .settings: return UICopy.settingsTitle
        }
    }
}

// MARK: - Active Workout presentation (reserved modal semantics, stubbed in #33)

/// Identifiable wrapper so the full-screen cover can bind to a session id.
public struct ActiveWorkoutPresentation: Identifiable, Hashable, Sendable {
    public let id: String   // workout_session.id

    public init(id: String) {
        self.id = id
    }
}

// MARK: - Boot failure (mapped onto SC-foundation §6 copy)

public struct BootFailure: Equatable, Sendable {
    /// Whether the failure is a migration failure (selects the §6 copy pair).
    public var isMigrationFailure: Bool
    /// Technical detail (shown small, for support; the §6 copy carries the message).
    public var detail: String

    public init(isMigrationFailure: Bool, detail: String) {
        self.isMigrationFailure = isMigrationFailure
        self.detail = detail
    }
}

// MARK: - AppState

@Observable
public final class AppState {
    /// Boot outcome — boot is synchronous in `AppState.boot()`; the app either
    /// arrives ready or shows the fatal-recovery surface.
    public enum Phase: Equatable {
        case ready
        case failed(BootFailure)
    }

    public let phase: Phase
    /// Nil only when phase == .failed.
    public let dependencies: AppDependencies?
    /// The Home surface model. Nil only when phase == .failed.
    public let home: HomeModel?

    /// Selected bottom tab (Home is the landing tab).
    public var selectedTab: AppTab = .home

    /// Active Workout full-screen cover hook (#33 stub; the money screen is #34).
    /// Non-nil ⇔ the modal is presented. Dismissal gesture is disabled — the only
    /// way down is the minimize chevron → mini-player (#7 §2).
    public var presentedWorkout: ActiveWorkoutPresentation?

    /// The live session summary driving the mini-player bar + Home resume card.
    /// Refreshed from SQLite (cold-render rule #9 r4), never from view state.
    public private(set) var activeSession: ActiveSessionSummary?

    private init(phase: Phase, dependencies: AppDependencies?, home: HomeModel?) {
        self.phase = phase
        self.dependencies = dependencies
        self.home = home
        if phase == .ready {
            self.activeSession = try? dependencies?.sessionStats.activeSession()
        }
    }

    /// The single boot entry point, called once by the @main App.
    public static func boot() -> AppState {
        do {
            let deps = try AppDependencies.boot()
            let home = HomeModel(
                surface: deps.homeSurface,
                routineDAO: deps.routineDAO,
                folderDAO: deps.folderDAO,
                materialize: deps.materialize
            )
            return AppState(phase: .ready, dependencies: deps, home: home)
        } catch let error as BootError {
            return AppState(
                phase: .failed(BootFailure(isMigrationFailure: error.isMigrationFailure, detail: "\(error)")),
                dependencies: nil,
                home: nil
            )
        } catch {
            return AppState(
                phase: .failed(BootFailure(isMigrationFailure: false, detail: "\(error)")),
                dependencies: nil,
                home: nil
            )
        }
    }

    // MARK: Active Workout presentation orchestration

    /// Present the Active Workout modal for a session (start / start-empty / resume).
    public func presentWorkout(sessionId: String) {
        presentedWorkout = ActiveWorkoutPresentation(id: sessionId)
        refreshActiveSession()
    }

    /// Minimize chevron → collapse to the mini-player bar (#7 §2). The session
    /// row stays live; dismissal never ends a session.
    public func minimizeWorkout() {
        presentedWorkout = nil
        refreshActiveSession()
    }

    /// Cold re-read of the in-flight session from SQLite.
    public func refreshActiveSession() {
        activeSession = try? dependencies?.sessionStats.activeSession()
    }
}
