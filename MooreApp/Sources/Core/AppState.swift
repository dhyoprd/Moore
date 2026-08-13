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
import MooreCues
import MooreRecords

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
    /// The Active Workout money-screen model (#34). Owned HERE — not by the
    /// presented view — so minimize → re-present keeps the same instance and
    /// the rest run's timestamps survive the cover's teardown (SC-rest BR-007).
    public private(set) var workout: WorkoutSessionModel?
    /// The Settings surface model (#38). Nil only when phase == .failed.
    public let settings: SettingsModel?
    /// The History surface model (#37): month-grouped sessions + PR badges +
    /// session detail (plan-vs-actual + e1RM sparklines). Drives the frozen
    /// AnalyticsEngine/AnalyticsDAO read seams; nil only when phase == .failed.
    public let history: HistoryModel?
    /// The Analytics surface model (#37): strictly-derived streak/adherence,
    /// Epley trend, weekly tonnage, muscle split, PR list. Nil only when
    /// phase == .failed.
    public let analytics: AnalyticsModel?
    /// The Hevy CSV import flow model (#39). Owned HERE — not by the settings
    /// row or the flow sheet — so the §2 machine survives the sheet's teardown
    /// and dismissal is a pure reset. Nil only when phase == .failed.
    public let importFlow: ImportModel?
    /// The full-taxonomy cue dispatcher (#36): one shared CueState across rest
    /// + set + PR cues so the celebration subsumes the per-set tick (SC-cues
    /// BR-008/INV-C4). Host lifecycle writes `context` (BR-005 foreground
    /// gate); the platform haptic sink is #40's seam. Nil when phase == .failed.
    public let cueDispatcher: CueDispatcher?

    /// Selected bottom tab (Home is the landing tab).
    public var selectedTab: AppTab = .home

    /// Active Workout full-screen cover hook. Non-nil ⇔ the modal is presented.
    /// Dismissal gesture is disabled — the only ways down are the minimize
    /// chevron → mini-player (#7 §2) or Finish/Discard through the session FSM.
    public var presentedWorkout: ActiveWorkoutPresentation?

    /// The live session summary driving the mini-player bar + Home resume card.
    /// Refreshed from SQLite (cold-render rule #9 r4), never from view state.
    public private(set) var activeSession: ActiveSessionSummary?

    private init(phase: Phase, dependencies: AppDependencies?, home: HomeModel?, workout: WorkoutSessionModel?, settings: SettingsModel?, history: HistoryModel?, analytics: AnalyticsModel?, importFlow: ImportModel?, cueDispatcher: CueDispatcher?) {
        self.phase = phase
        self.dependencies = dependencies
        self.home = home
        self.workout = workout
        self.settings = settings
        self.history = history
        self.analytics = analytics
        self.importFlow = importFlow
        self.cueDispatcher = cueDispatcher
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
                progression: deps.progression
            )
            // Cue delivery (#36): the full-taxonomy MooreCues dispatcher over
            // the ABSTRACT recording sink — the platform haptic driver for the
            // celebration/success/alert classes is #40's seam. One shared
            // CueState across rest + set + PR cues so the PR celebration
            // subsumes the per-set tick (SC-cues BR-008 / INV-C4).
            let dispatcher = CueDispatcher(sink: RecordingCueSink())
            // PR + celebrations model (#36): drives the frozen PREngine +
            // PersonalRecordDAO + CueEngine; the workout flow calls it after
            // every committed transition.
            let records = RecordsModel(
                prDAO: deps.personalRecordDAO,
                exerciseDAO: deps.exerciseDAO,
                settingsDAO: deps.settingsDAO,
                cueChannel: dispatcher
            )
            let workout = WorkoutSessionModel(
                dbQueue: deps.dbQueue,
                sessionDAO: deps.sessionDAO,
                exerciseDAO: deps.exerciseDAO,
                routineDAO: deps.routineDAO,
                materialize: deps.materialize,
                restSettingsDAO: deps.restSettingsDAO,
                settingsDAO: deps.settingsDAO,
                sessionStats: deps.sessionStats,
                progression: deps.progression,
                cueChannel: dispatcher,
                records: records
            )
            let settings = SettingsModel(dao: deps.settingsDAO)
            // History + Analytics (#37): strictly-derived read surfaces driving
            // the frozen AnalyticsEngine/AnalyticsDAO + the #36 PR-badge probe.
            let history = HistoryModel(
                analyticsDAO: deps.analyticsDAO,
                prDAO: deps.personalRecordDAO,
                settingsDAO: deps.settingsDAO
            )
            let analytics = AnalyticsModel(
                analyticsDAO: deps.analyticsDAO,
                settingsDAO: deps.settingsDAO
            )
            // Hevy CSV import flow (#39): drives the frozen HevyImportEngine
            // (seam-1 plan build) + HevyImportDAO (seam-2 atomic apply + PR
            // re-derivation) — SC-import@1.0.0.
            let importFlow = ImportModel(dao: deps.hevyImportDAO)
            return AppState(phase: .ready, dependencies: deps, home: home, workout: workout, settings: settings, history: history, analytics: analytics, importFlow: importFlow, cueDispatcher: dispatcher)
        } catch let error as BootError {
            return AppState(
                phase: .failed(BootFailure(isMigrationFailure: error.isMigrationFailure, detail: "\(error)")),
                dependencies: nil,
                home: nil,
                workout: nil,
                settings: nil,
                history: nil,
                analytics: nil,
                importFlow: nil,
                cueDispatcher: nil
            )
        } catch {
            return AppState(
                phase: .failed(BootFailure(isMigrationFailure: false, detail: "\(error)")),
                dependencies: nil,
                home: nil,
                workout: nil,
                settings: nil,
                history: nil,
                analytics: nil,
                importFlow: nil,
                cueDispatcher: nil
            )
        }
    }

    // MARK: Active Workout presentation orchestration

    /// Present the Active Workout modal for a session (resume). Adopts the
    /// session into the owned model — cold re-read from SQLite (#9 r4).
    public func presentWorkout(sessionId: String) {
        guard let workout else { return }
        if workout.sessionId != sessionId {
            _ = workout.attach(sessionId: sessionId)
        } else {
            // Same session re-presented (mini-player tap): recompute any live
            // rest run from its timestamps (BR-007), nothing else changes.
            workout.sceneBecameActive()
        }
        presentedWorkout = ActiveWorkoutPresentation(id: sessionId)
        refreshActiveSession()
    }

    /// Home's Start CTA (#34 wiring): materialise the routine's planned sets
    /// into a fresh session and present the money screen.
    public func startWorkout(routineId: String) {
        guard let workout else { return }
        if workout.start(routineId: routineId), let sessionId = workout.sessionId {
            home?.refresh()
            presentedWorkout = ActiveWorkoutPresentation(id: sessionId)
            refreshActiveSession()
        }
    }

    /// Home's Start-empty CTA (#34 wiring): ad-hoc session, zero rows.
    public func startWorkoutEmpty() {
        guard let workout else { return }
        if workout.startEmpty(), let sessionId = workout.sessionId {
            home?.refresh()
            presentedWorkout = ActiveWorkoutPresentation(id: sessionId)
            refreshActiveSession()
        }
    }

    /// Minimize chevron → collapse to the mini-player bar (#7 §2). The session
    /// row AND the workout model stay live; dismissal never ends a session.
    public func minimizeWorkout() {
        presentedWorkout = nil
        refreshActiveSession()
    }

    /// Summary Done (#34): the session is finished (endedAt stamped) — drop the
    /// modal and re-read Home + the mini-player. The model keeps the finished
    /// session's id harmlessly; the next start()/attach() re-adopts a new one.
    public func closeFinishedWorkout() {
        presentedWorkout = nil
        refreshActiveSession()
        home?.refresh()
    }

    /// Scene foreground: recompute any live rest run from timestamps (BR-007).
    public func sceneBecameActive() {
        workout?.sceneBecameActive()
    }

    /// Scene lifecycle → cue device context (SC-cues BR-005/INV-C6): only
    /// cue.rest.end reaches a backgrounded/locked device; the PR celebration
    /// is foreground-only BY CONSTRUCTION because the engine gates on this.
    /// `silenced` is preserved — it is the host's audio-axis surface.
    public func scenePhaseChanged(isActive: Bool) {
        guard let cueDispatcher else { return }
        var context = cueDispatcher.context
        context.appState = isActive ? .foreground : .backgroundedOrLocked
        cueDispatcher.context = context
    }

    /// Cold re-read of the in-flight session from SQLite.
    public func refreshActiveSession() {
        activeSession = try? dependencies?.sessionStats.activeSession()
    }
}
