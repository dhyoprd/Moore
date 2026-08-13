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
    /// The full-taxonomy cue dispatcher (#36): one shared CueState across rest
    /// + set + PR cues so the celebration subsumes the per-set tick (SC-cues
    /// BR-008/INV-C4). Host lifecycle writes `context` (BR-005 foreground
    /// gate). #40: the sink is the platform renderer (PlatformCueSink) composed
    /// with the recording spy — nil dispatcher only when phase == .failed.
    public let cueDispatcher: CueDispatcher?
    /// #40: the visual pulse surface (SC-cues INV-C3). The platform sink
    /// publishes every rendered cue's visual element here; overlays bind it
    /// for emphasis. Nil only when phase == .failed.
    public let cueVisualPulse: CueVisualPulse?
    /// #40: rest-end notification-class delivery (SC-cues BR-005 host
    /// scheduling contract) — the summoner surface for backgrounded/locked
    /// rest expiry (INV-C6). Noop on the boot-failure path.
    public let restEndNotifier: any RestEndNotificationScheduling

    /// Selected bottom tab (Home is the landing tab).
    public var selectedTab: AppTab = .home

    /// Active Workout full-screen cover hook. Non-nil ⇔ the modal is presented.
    /// Dismissal gesture is disabled — the only ways down are the minimize
    /// chevron → mini-player (#7 §2) or Finish/Discard through the session FSM.
    public var presentedWorkout: ActiveWorkoutPresentation?

    /// The live session summary driving the mini-player bar + Home resume card.
    /// Refreshed from SQLite (cold-render rule #9 r4), never from view state.
    public private(set) var activeSession: ActiveSessionSummary?

    private init(phase: Phase, dependencies: AppDependencies?, home: HomeModel?, workout: WorkoutSessionModel?, settings: SettingsModel?, cueDispatcher: CueDispatcher?, cueVisualPulse: CueVisualPulse?, restEndNotifier: any RestEndNotificationScheduling) {
        self.phase = phase
        self.dependencies = dependencies
        self.home = home
        self.workout = workout
        self.settings = settings
        self.cueDispatcher = cueDispatcher
        self.cueVisualPulse = cueVisualPulse
        self.restEndNotifier = restEndNotifier
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
            // Cue delivery (#40): the platform renderer replaces the #36 spy
            // at boot. CompositeCueSink keeps the RecordingCueSink live so
            // diagnostics still see every rendered channel call; the ring
            // buffer (BR-013) rides CueState either way (cueDispatcher.cueLog).
            // Cue DECISIONS stay in CueEngine — the sinks render only what the
            // engine fires. One shared CueState across rest + set + PR cues so
            // the PR celebration subsumes the per-set tick (BR-008 / INV-C4).
            let visualPulse = CueVisualPulse()
            let dispatcher = CueDispatcher(sink: CompositeCueSink(sinks: [
                PlatformCueSink(visualPulse: visualPulse),
                RecordingCueSink(),
            ]))
            let restEndNotifier: any RestEndNotificationScheduling = RestEndNotificationScheduler()
            // PR + celebrations model (#36): drives the frozen PREngine +
            // PersonalRecordDAO + CueEngine; the workout flow calls it after
            // every committed transition.
            let records = RecordsModel(
                prDAO: PersonalRecordDAO(dbQueue: deps.dbQueue),
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
            return AppState(
                phase: .ready,
                dependencies: deps,
                home: home,
                workout: workout,
                settings: settings,
                cueDispatcher: dispatcher,
                cueVisualPulse: visualPulse,
                restEndNotifier: restEndNotifier
            )
        } catch let error as BootError {
            return AppState(
                phase: .failed(BootFailure(isMigrationFailure: error.isMigrationFailure, detail: "\(error)")),
                dependencies: nil,
                home: nil,
                workout: nil,
                settings: nil,
                cueDispatcher: nil,
                cueVisualPulse: nil,
                restEndNotifier: NoopRestEndNotifier()
            )
        } catch {
            return AppState(
                phase: .failed(BootFailure(isMigrationFailure: false, detail: "\(error)")),
                dependencies: nil,
                home: nil,
                workout: nil,
                settings: nil,
                cueDispatcher: nil,
                cueVisualPulse: nil,
                restEndNotifier: NoopRestEndNotifier()
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
        // #40: the one notification permission prompt rides the FIRST workout
        // start — never mid-set. The scheduler guards the once-semantics.
        restEndNotifier.requestAuthorizationOnce()
        if workout.start(routineId: routineId), let sessionId = workout.sessionId {
            home?.refresh()
            presentedWorkout = ActiveWorkoutPresentation(id: sessionId)
            refreshActiveSession()
        }
    }

    /// Home's Start-empty CTA (#34 wiring): ad-hoc session, zero rows.
    public func startWorkoutEmpty() {
        guard let workout else { return }
        restEndNotifier.requestAuthorizationOnce()
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
        // #40: finish cancels the rest-end summons (SC-cues BR-005 host
        // scheduling contract) — a finished session never rings.
        restEndNotifier.cancelPendingRestEnd()
        restEndNotifier.removeDeliveredRestEnd()
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
    ///
    /// #40 — this is also the BR-005 host scheduling contract for the rest-end
    /// summoner: backgrounding mid-run schedules the local notification at the
    /// run's expiry instant; foreground cancels it (the in-process cue takes
    /// over — and within the grace window the delivered notification is
    /// removed in favor of the in-process cue, first-deliverable-opportunity).
    public func scenePhaseChanged(isActive: Bool) {
        if let cueDispatcher {
            var context = cueDispatcher.context
            context.appState = isActive ? .foreground : .backgroundedOrLocked
            cueDispatcher.context = context
        }
        if isActive {
            restEndNotifier.cancelPendingRestEnd()
            if let expiry = workout?.restExpiresAt,
               Date().timeIntervalSince(expiry) <= CueState.backgroundedNotificationGraceSec {
                restEndNotifier.removeDeliveredRestEnd()
            }
            workout?.sceneBecameActive()
        } else {
            scheduleRestEndNotificationIfRunning()
        }
    }

    /// BR-005 host scheduling: the scene backgrounded while a rest run is
    /// still live ⇒ schedule the rest-end notification for the run's expiry
    /// (timestamps are authoritative — BR-007). An already-expired run has
    /// cued in-process already; nothing to schedule.
    private func scheduleRestEndNotificationIfRunning() {
        guard let workout,
              let expiry = workout.restExpiresAt,
              expiry > Date(),
              let next = workout.restOverDescription
        else { return }
        restEndNotifier.scheduleRestEnd(
            expiry: expiry,
            exerciseName: next.exerciseName,
            setNumber: next.n,
            setTotal: next.total
        )
    }

    // MARK: Blocking-confirm seam (SC-cues BR-010 / §2b)

    /// A confirm-first destructive action was invoked (delete routine / delete
    /// folder / discard session): evaluate cue.confirm.destructive — the ONLY
    /// blocking cue (INV-C5). The dialog itself is the visual element
    /// (confirm.modal); the engine sets pendingConfirmation and the write gate
    /// is explicit acceptance via confirmResolved().
    public func confirmInvoked() {
        cueDispatcher?.dispatch(CueEvent(name: .confirmDestructive, at: Date()))
    }

    /// §2b exit — explicit acceptance (the destructive write may now execute)
    /// or explicit rejection (it must not). Idempotent: dismissal and the
    /// accept action both land here; nothing else resolves a confirm.
    public func confirmResolved() {
        cueDispatcher?.resolveConfirmation()
    }

    /// Cold re-read of the in-flight session from SQLite.
    public func refreshActiveSession() {
        activeSession = try? dependencies?.sessionStats.activeSession()
    }
}
