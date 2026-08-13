// Ticket #34 — Active Workout money screen state. Foundation-only (@Observable,
// no SwiftUI) so it parses/verifies off-Mac; the SwiftUI layer in Views/ binds
// to this surface and stays thin.
//
// Architecture: this class OWNS the live session and DRIVES the frozen pure
// engines — it never reimplements them:
//   • WorkoutSessionFSM + Materialize + WorkoutSessionDAO (SC-workout-logging
//     @1.0.0): every user gesture is an FsmAction; dispatch is the single write
//     entry point (§5); the DAO is the FSM's seam-2 persistence adapter.
//   • RestCycle + RestResolver + RestSettingsDAO (SC-rest @1.0.0): rest starts
//     itself at every completed/failed set (BR-001 resolution at log moment),
//     skip/±15s are one-off, and the §2b finish morph rides the overlay axis.
//
// Persistence doctrine (#9 rule 4): after every lawful transition the model
// persists via the DAO, then cold re-reads the FSM from SQLite — state is
// recomputed from rows, never carried on faith. The BR-003 drop-undo window is
// the one documented exception: SC-workout-logging §8 rejects deriving it from
// stored data, so the model carries it as session logic.
//
// Wall-clock ownership: SC-rest §9 pins `at:` on #22 — every RestAction carries
// its instant from here; the rest engine never reads time itself.

import Foundation
import Observation
import GRDB
import MooreWorkout
import MooreRest
import MooreExercises
import MooreRoutines
import MooreSettings
import MooreProgression

// MARK: - Edit sheet request (§2a: editing is transient UI, never an FSM state)

/// What the bottom-sheet edit surface is doing. Presented by the money screen;
/// the sheet's Done tap maps onto exactly one FsmAction per mode.
public struct SetEditRequest: Identifiable, Equatable {
    public enum Mode: Equatable {
        /// planned row, tap body / ✓-and-hold path → `editAndAccept` (BR-001
        /// edited variant: user-adjusted actuals, plannedX untouched).
        case log
        /// planned row, swipe-left Failed → `fail` (BR-002: sheet pre-tagged
        /// failed, weight pre-filled from planned, reps focused for the count).
        case fail
        /// completed row correction → `editCompleted` (BR-006: no rest, no cue).
        case correctCompleted
        /// failed row correction → `editFailed` (BR-006's symmetric case).
        case correctFailed
    }

    public let id: String                    // completed_set.id
    public var mode: Mode
    public var exerciseName: String
    public var isDurationMetric: Bool
    /// Plate preview applies to plate-loadable barbell rows only.
    public var showsPlatePreview: Bool
    /// Seed values in canonical kg (the sheet renders them in the display unit).
    public var weightKg: Double?
    public var reps: Int?
    public var durationSec: Int?

    /// Sheet title copy (workout.edit.title / workout.edit.failTitle).
    public var isFailMode: Bool {
        switch mode {
        case .fail, .correctFailed: return true
        case .log, .correctCompleted: return false
        }
    }
}

// MARK: - Finish summary (plan-vs-actual surface)

/// One row of the summary's plan-vs-actual table.
public struct SessionSummaryRow: Identifiable, Equatable {
    public let id: String
    public let exerciseName: String
    /// Qualified: #35 imports MooreProgression here too, which exports its own
    /// SetStatus — the money-screen row state is MooreWorkout's.
    public let status: MooreWorkout.SetStatus
    public let plannedText: String
    public let actualText: String
}

/// The `finishSession` read surface: plan-vs-actual for the whole gym visit.
public struct SessionSummary: Equatable {
    public let routineName: String?
    public let startedAt: Date
    public let endedAt: Date
    public let setCount: Int
    public let setsDone: Int
    public let setsFailed: Int
    public let setsDropped: Int
    public let exerciseCount: Int
    /// Σ(actualWeight × actualReps) over completed WORK sets (SC-routines §3b
    /// volume shape; warmups excluded per INV-6's coalesce).
    public let volumeKg: Double
    public let rows: [SessionSummaryRow]
    /// The session's PR cards (SC-prs BR-010 / INV-PR5): precedence-ordered,
    /// read at render time by RecordsModel. 0 → no section; 1 → single card;
    /// ≥2 → banner + stacked cards (Summary owns ALL escalation, BR-011).
    public let prCards: [PRSummaryCard]
}

/// One exercise group of the flat, order-free set list (group order = first
/// appearance in sortOrder — the §5 readModel render shape).
public struct ExerciseGroup: Identifiable {
    public let exerciseId: String
    public let name: String
    public let sets: [SetSnapshot]

    public var id: String { exerciseId }
}

/// Which bottom surface the money screen presents.
public enum WorkoutOverlaySurface: Equatable {
    case none
    /// Rest countdown / rest-over state (SC-rest §2a).
    case rest
    /// The §2b morph target: all sets terminal and the final rest consumed.
    case finishPanel
}

// MARK: - WorkoutSessionModel

@Observable
public final class WorkoutSessionModel {

    // MARK: Observable surface (the money screen renders ONLY this)

    /// The FSM read surface (§5 `state`).
    public private(set) var snapshot: StateSnapshot
    /// The rest-cycle surface (SC-rest §5). In-memory only (INV-T2).
    public private(set) var restCycle: RestCycle
    /// Drop-undo affordance (BR-003). Session logic carried by the model —
    /// never derivable from rows (§8), never timer-bounded (#10).
    public private(set) var undoableDrop: UndoableDrop?
    /// Bottom-sheet presentation hook (nil ⇔ closed). Transient UI (§2a).
    public var editRequest: SetEditRequest?
    /// Non-nil ⇔ session finished; the summary surface replaces the list.
    public private(set) var summary: SessionSummary?
    /// workout.title input; nil ⇒ ad-hoc session (workout.adhoc_title).
    public private(set) var routineName: String?
    public private(set) var sessionStartedAt: Date?
    public private(set) var errorMessage: String?
    /// Display unit (SC-settings BR-001: display-only toggle; storage is kg).
    public private(set) var weightUnit: WeightUnit = .kg

    /// The session this model drives (workout_session.id).
    public private(set) var sessionId: String?

    // MARK: Engines & seams (driven, never reimplemented)

    private var fsm: WorkoutSessionFSM?
    private let dbQueue: DatabaseQueue
    private let sessionDAO: WorkoutSessionDAO
    private let exerciseDAO: ExerciseDAO
    private let routineDAO: RoutineDAO
    private let materialize: Materialize
    private let restSettingsDAO: RestSettingsDAO
    private let settingsDAO: SettingsDAO
    private let sessionStats: SessionStatsProvider
    /// #35 — progression + warm-up + stall state. Driven at the materialization
    /// seam (stamped plannedX BEFORE rows render), at finish (stall counters),
    /// and by the stall-banner gestures. All its logic is Foundation-only in
    /// ProgressionModel.swift.
    public let progression: ProgressionModel
    /// The cue channel (SC-rest §5 + SC-cues §5). Production wiring is the
    /// shared CueDispatcher: it accepts SC-rest's two-case emission here AND
    /// the full-taxonomy events (set witnesses below; PR cues via
    /// RecordsModel), all through one shared CueState.
    public let cueChannel: any CueDispatching & FullCueDispatching
    /// The PR + celebrations model (#36): drives PREngine + PersonalRecordDAO
    /// + CueEngine for the live completion path, corrections, and the Summary
    /// surface. Owned by AppState; shared, never re-created per session.
    public let records: RecordsModel

    // Session-scoped BR-001 inputs, loaded once at attach so resolution never
    // reaches into the database mid-session (SC-rest §5 resolver contract).
    private var routineId: String?
    private var exercisesById: [String: Exercise] = [:]
    /// Level 1 per-set overrides (planned_set.restDurationSec) by set id.
    private var perSetRestSec: [String: Int?] = [:]
    /// Level 3 per-routine override (routine.restSec).
    private var routineRestSec: Int?
    /// Level 4 global defaults (app_setting rows, seeded by 0008).
    private var restSettings: RestSettings = .default

    public init(
        dbQueue: DatabaseQueue,
        sessionDAO: WorkoutSessionDAO,
        exerciseDAO: ExerciseDAO,
        routineDAO: RoutineDAO,
        materialize: Materialize,
        restSettingsDAO: RestSettingsDAO,
        settingsDAO: SettingsDAO,
        sessionStats: SessionStatsProvider,
        progression: ProgressionModel,
        cueChannel: any CueDispatching & FullCueDispatching,
        records: RecordsModel
    ) {
        self.dbQueue = dbQueue
        self.sessionDAO = sessionDAO
        self.exerciseDAO = exerciseDAO
        self.routineDAO = routineDAO
        self.materialize = materialize
        self.restSettingsDAO = restSettingsDAO
        self.settingsDAO = settingsDAO
        self.sessionStats = sessionStats
        self.progression = progression
        self.cueChannel = cueChannel
        self.records = records
        self.snapshot = StateSnapshot(sessionId: "")
        self.restCycle = RestCycle()
    }

    // MARK: Session lifecycle

    /// Start from a routine (§5 Materialize): snapshot-copy the routine's live
    /// planned sets — plannedX stamped with the progression engine's suggestion
    /// (#35 BR-018: the planned row text IS the suggestion), actualX NULL,
    /// contiguous sortOrder — then attach. Returns success.
    @discardableResult
    public func start(routineId: String) -> Bool {
        do {
            let plannedSets = try routineDAO.fetchSets(routineId: routineId)
            guard !plannedSets.isEmpty else { return false }   // BR-001 guard
            // #35: progression stamping BEFORE the rows render. Phase 1 runs the
            // engine's suggest per pair (session-1 pairs keep blueprint verbatim,
            // SC-progression BR-003); phase 2 (post-create) persists the engine's
            // record mutations and derives the warm-up ramp off the stamped
            // working weights (SC-warmup BR-001/BR-008).
            let prepared = try progression.prepareMaterialization(routineId: routineId, plannedSets: plannedSets)
            let newSessionId = try materialize.startSession(routineId: routineId, plannedSets: prepared.inputs)
            progression.finishMaterialization(sessionId: newSessionId, prepared: prepared)
            return attach(sessionId: newSessionId)
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    /// Start empty — ad-hoc session, `routineId = NULL`, zero rows (#14 §1).
    @discardableResult
    public func startEmpty() -> Bool {
        do {
            let newSessionId = try materialize.startSession(routineId: nil, plannedSets: [])
            return attach(sessionId: newSessionId)
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    /// Cold render (#9 rule 4): rebuild the FSM from rows and adopt the session.
    /// This is ALSO the resume path (mini-player tap, app foreground) — state is
    /// recomputed from SQLite, never from a daemon or stale view state.
    @discardableResult
    public func attach(sessionId: String) -> Bool {
        do {
            let reloaded = try sessionDAO.fetchSessionState(sessionId: sessionId)
            self.sessionId = sessionId
            self.fsm = reloaded
            self.snapshot = reloaded.state
            self.undoableDrop = nil
            // BR-007: nothing of a rest run is recoverable from disk (INV-T2) —
            // a re-attach starts in noRest; live models keep their timestamps.
            self.restCycle = RestCycle()
            self.summary = nil
            self.editRequest = nil
            // #36: celebrations are session-scoped ephemera — a new session
            // never inherits the previous one's toast queue.
            self.records.resetCelebrations()

            if let active = try? sessionStats.activeSession(), active.id == sessionId {
                self.routineName = active.routineName
                self.sessionStartedAt = active.startedAt
            }

            self.routineId = try dbQueue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT routineId FROM workout_session WHERE id = ?",
                    arguments: [sessionId]
                )
            }
            if let routineId {
                self.routineRestSec = try dbQueue.read { db in
                    try Int.fetchOne(db, sql: "SELECT restSec FROM routine WHERE id = ?", arguments: [routineId])
                }
            } else {
                self.routineRestSec = nil
            }

            loadExercises()
            loadPerSetRestOverrides()
            loadSettings()
            // #35: cold re-derive the stall-banner surface for this session
            // (BR-013's condition is durable; dismissals are transient UI and
            // intentionally don't survive the re-attach — INV-T2 precedent).
            progression.adoptSession(sessionId: sessionId, routineId: routineId)
            self.errorMessage = nil
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    // MARK: Derived render surface

    /// Flat set list grouped by exercise (group order = first appearance).
    public var groups: [ExerciseGroup] {
        var order: [String] = []
        var byExercise: [String: [SetSnapshot]] = [:]
        for set in snapshot.sets {
            if byExercise[set.exerciseId] == nil { order.append(set.exerciseId) }
            byExercise[set.exerciseId, default: []].append(set)
        }
        return order.map { exerciseId in
            ExerciseGroup(
                exerciseId: exerciseId,
                name: exerciseName(exerciseId),
                sets: byExercise[exerciseId] ?? []
            )
        }
    }

    /// INV-W1: "next up" is a derived highlight — the first non-terminal row —
    /// never an enforced cursor.
    public var nextIncompleteSetId: String? { snapshot.nextIncompleteSetId }

    /// BR-008: every set terminal ⇒ the finish affordance is live.
    public var finishReady: Bool { snapshot.finishRequested }

    /// The bottom surface to present. SC-rest §2b routes the morph through the
    /// rest run's end; the rest-less edge (the final transition was a drop, so
    /// no run exists to consume) presents the finish panel directly — dropped
    /// sets are terminal for the morph check but never request rest (BR-008).
    public var overlaySurface: WorkoutOverlaySurface {
        if summary != nil { return .none }
        if restCycle.overlay == .finishPanel { return .finishPanel }
        switch restCycle.state {
        case .restRunning, .restExpired:
            return .rest
        case .noRest:
            return finishReady ? .finishPanel : .none
        }
    }

    /// Absolute expiry of the live run (BR-007: computed from timestamps,
    /// never ticked, never stored).
    public var restExpiresAt: Date? {
        switch restCycle.state {
        case let .restRunning(durationSec, startedAt, adjustmentSec),
             let .restExpired(durationSec, startedAt, adjustmentSec):
            return RestCycle.expiresAt(durationSec: durationSec, startedAt: startedAt, adjustmentSec: adjustmentSec)
        case .noRest:
            return nil
        }
    }

    public func restRemainingSec(at now: Date) -> Int {
        switch restCycle.state {
        case let .restRunning(durationSec, startedAt, adjustmentSec):
            return RestCycle.remainingSec(durationSec: durationSec, startedAt: startedAt, adjustmentSec: adjustmentSec, now: now)
        case .restExpired, .noRest:
            return 0
        }
    }

    /// rest.over.body inputs — the next incomplete row's exercise + ordinal.
    public var restOverDescription: (exerciseName: String, n: Int, total: Int)? {
        guard let setId = snapshot.nextIncompleteSetId,
              let set = snapshot.sets.first(where: { $0.id == setId })
        else { return nil }
        let sameExercise = snapshot.sets.filter { $0.exerciseId == set.exerciseId }
        let ordinal = (sameExercise.firstIndex(where: { $0.id == setId }) ?? 0) + 1
        return (exerciseName(set.exerciseId), ordinal, sameExercise.count)
    }

    /// Header elapsed slot — mm:ss from startedAt.
    public func elapsedText(at now: Date) -> String {
        guard let startedAt = sessionStartedAt else { return "" }
        return UICopy.restOverlayRemaining(seconds: max(0, Int(now.timeIntervalSince(startedAt))))
    }

    /// rest.finish.summary — the morph panel's mini-summary (SC-rest §6).
    public func finishPanelText(at now: Date) -> String {
        let setCount = snapshot.sets.count
        let exerciseCount = Set(snapshot.sets.map(\.exerciseId)).count
        let duration = sessionStartedAt.map {
            UICopy.restOverlayRemaining(seconds: max(0, Int(now.timeIntervalSince($0))))
        } ?? "0:00"
        return UICopy.restFinishSummary(setCount: setCount, exerciseCount: exerciseCount, duration: duration)
    }

    /// SC-settings BR-001: the display-unit toggle is the ONE settings write —
    /// it never touches training data (storage stays canonical kg, INV-ST2).
    public func toggleWeightUnit() {
        let newUnit: WeightUnit = weightUnit == .kg ? .lb : .kg
        let now = ISO8601DateFormatter().string(from: Date())
        try? settingsDAO.setWeightUnit(newUnit, at: now)
        weightUnit = newUnit
    }

    // MARK: Row text (contract copy shapes, display-unit aware)

    /// Canonical kg → display-unit render (SC-settings BR-002 frozen shape).
    public func displayWeight(_ kg: Double?) -> String {
        guard let kg else { return "—" }
        return SettingsEngine.displayString(rawKg: kg, unit: weightUnit)
    }

    public func isDurationMetric(_ exerciseId: String) -> Bool {
        exercisesById[exerciseId]?.defaultMetric == .duration
    }

    /// workout.set.plannedValue / workout.set.durationValue shapes.
    public func plannedText(for set: SetSnapshot) -> String {
        if isDurationMetric(set.exerciseId) {
            guard let duration = set.plannedDurationSec else { return "—" }
            return UICopy.workoutSetDurationValue(duration: UICopy.restOverlayRemaining(seconds: duration))
        }
        guard let weight = set.plannedWeight, let reps = set.plannedReps else { return "—" }
        return UICopy.workoutSetPlannedValue(weight: displayWeight(weight), reps: reps)
    }

    /// workout.set.doneDelta / failedDelta / dropped shapes.
    public func actualText(for set: SetSnapshot) -> String {
        switch set.status {
        case .planned:
            return ""
        case .completed:
            if isDurationMetric(set.exerciseId), let duration = set.actualDurationSec {
                return UICopy.workoutSetDurationValue(duration: UICopy.restOverlayRemaining(seconds: duration))
            }
            return UICopy.workoutSetDoneDelta(
                actualWeight: displayWeight(set.actualWeight),
                actualReps: set.actualReps ?? 0
            )
        case .failed:
            return UICopy.workoutSetFailedDelta(
                actualReps: set.actualReps ?? 0,
                plannedWeight: displayWeight(set.plannedWeight),
                plannedReps: set.plannedReps ?? 0
            )
        case .dropped:
            return UICopy.workoutSetDropped
        }
    }

    public func set(byId id: String) -> SetSnapshot? {
        snapshot.sets.first { $0.id == id }
    }

    /// #35: stall-choice passthrough for the Active Workout banner — the pair
    /// context is this session's routine; the choice semantics (Deload/Hold/
    /// Ignore) live in ProgressionModel → ProgressionEngine.
    public func applyStallChoice(_ action: StallAction, exerciseId: String) {
        guard let routineId else { return }   // ad-hoc sessions carry no pairs
        progression.applyStallChoice(action, routineId: routineId, exerciseId: exerciseId)
    }

    public func exerciseName(_ exerciseId: String) -> String {
        exercisesById[exerciseId]?.name ?? exerciseId
    }

    public func exercise(for exerciseId: String) -> Exercise? {
        exercisesById[exerciseId]
    }

    // MARK: Money-screen gestures (§5: dispatch is the single entry point)

    /// ✓ on a `planned` row — BR-001's 1-tap field-copy (actualX = plannedX).
    @discardableResult
    public func accept(setId: String) -> Bool {
        dispatchTerminal(.accept(setId: setId))
    }

    /// Tap on any row → the bottom sheet (BR-005: editing is exclusively the
    /// sheet path; rows carry no inline steppers).
    public func openEdit(setId: String) {
        guard let set = set(byId: setId) else { return }
        switch set.status {
        case .planned:
            editRequest = SetEditRequest(
                id: setId, mode: .log,
                exerciseName: exerciseName(set.exerciseId),
                isDurationMetric: isDurationMetric(set.exerciseId),
                showsPlatePreview: showsPlatePreview(set.exerciseId),
                weightKg: set.plannedWeight, reps: set.plannedReps, durationSec: set.plannedDurationSec
            )
        case .completed:
            editRequest = SetEditRequest(
                id: setId, mode: .correctCompleted,
                exerciseName: exerciseName(set.exerciseId),
                isDurationMetric: isDurationMetric(set.exerciseId),
                showsPlatePreview: showsPlatePreview(set.exerciseId),
                weightKg: set.actualWeight, reps: set.actualReps, durationSec: set.actualDurationSec
            )
        case .failed:
            editRequest = SetEditRequest(
                id: setId, mode: .correctFailed,
                exerciseName: exerciseName(set.exerciseId),
                isDurationMetric: isDurationMetric(set.exerciseId),
                showsPlatePreview: showsPlatePreview(set.exerciseId),
                weightKg: set.actualWeight, reps: set.actualReps, durationSec: set.actualDurationSec
            )
        case .dropped:
            break   // §2a: no edit out of dropped — undo is the only path back
        }
    }

    /// Swipe-left → Failed (BR-002): sheet pre-tagged failed, weight pre-filled
    /// from planned, reps empty + focused for the actual count.
    public func openFail(setId: String) {
        guard let set = set(byId: setId), set.status == .planned else { return }
        editRequest = SetEditRequest(
            id: setId, mode: .fail,
            exerciseName: exerciseName(set.exerciseId),
            isDurationMetric: isDurationMetric(set.exerciseId),
            showsPlatePreview: showsPlatePreview(set.exerciseId),
            weightKg: set.plannedWeight, reps: nil, durationSec: set.plannedDurationSec
        )
    }

    /// The sheet's Done tap (3rd tap of the edit path). Values arrive in the
    /// active display unit; canonical storage is kg (SC-settings INV-ST2).
    @discardableResult
    public func commitEdit(displayWeight: Double?, reps: Int?, durationSec: Int?) -> Bool {
        guard let request = editRequest else { return false }
        let weightKg = displayWeight.map { SettingsEngine.entryToStorage($0, unit: weightUnit) }
        let exerciseId = set(byId: request.id)?.exerciseId
        editRequest = nil
        switch request.mode {
        case .log:
            let ok = dispatchTerminal(.editAndAccept(setId: request.id, weight: weightKg, reps: reps, durationSec: durationSec))
            if ok, let exerciseId {
                // SC-progression BR-018: the bottom-sheet edit overrides the
                // suggestion surface and silently resets the pair's stall chain.
                progression.resetChainForPair(routineId: routineId, exerciseId: exerciseId)
            }
            return ok
        case .fail:
            // BR-002: actuals are mandatory — zero-data failure was rejected (#2).
            guard reps != nil || durationSec != nil else { return false }
            return dispatchTerminal(.fail(setId: request.id, weight: weightKg, reps: reps, durationSec: durationSec))
        case .correctCompleted:
            return dispatchTerminal(.editCompleted(setId: request.id, weight: weightKg, reps: reps, durationSec: durationSec), requestsRest: false)
        case .correctFailed:
            return dispatchTerminal(.editFailed(setId: request.id, weight: weightKg, reps: reps, durationSec: durationSec), requestsRest: false)
        }
    }

    /// Swipe-left → Drop set (BR-003): instant, no actuals, NO rest requested;
    /// opens the undo window (lives until the next logged set, no timer).
    @discardableResult
    public func drop(setId: String) -> Bool {
        guard var machine = fsm else { return false }
        let result = machine.dispatch(.drop(setId: setId))
        guard case .success = result else {
            if case .failure(let reason, _) = result { errorMessage = reason }
            return false
        }
        do {
            if let post = machine.state.sets.first(where: { $0.id == setId }) {
                try sessionDAO.updateSetStatus(
                    setId: setId, status: .dropped,
                    actualWeight: nil, actualReps: nil, actualDuration: nil,
                    completedAt: post.completedAt
                )
            }
            undoableDrop = UndoableDrop(setId: setId, available: true)
            _ = restCycle.dispatch(.setDropped)   // BR-005: faithful no-op
            // #40: the drop witness (SC-cues §3a cue.set.dropped) — visual-only
            // by construction (BR-009: no haptic, the undo toolbar IS the cue;
            // undoing fires nothing). Post-commit (BR-011).
            cueChannel.dispatch(MooreCues.CueEvent(name: .setDropped, at: Date(), setId: setId))
            reloadFSM()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    /// Undo the outstanding drop, lawful only while the window is open (BR-003).
    @discardableResult
    public func undoDrop() -> Bool {
        guard let undo = undoableDrop, undo.available, var machine = fsm else { return false }
        let result = machine.dispatch(.undoDrop(setId: undo.setId))
        guard case .success = result else {
            // The FSM is authoritative: a refused undo means the window closed.
            undoableDrop = nil
            return false
        }
        do {
            try sessionDAO.undoDropSet(setId: undo.setId)
            undoableDrop = nil
            reloadFSM()
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    /// `[+]` in an exercise-group header (BR-004): append a `planned` row at
    /// `sortOrder = count`, pre-filled from that exercise's last row. Dropsets
    /// are emergent; adding a set never requests rest.
    @discardableResult
    public func addSet(exerciseId: String) -> Bool {
        guard var machine = fsm, let sessionId else { return false }
        // Template read BEFORE dispatch — the FSM copies these same values
        // in-memory; the DB append mirrors them, then the cold re-read aligns ids.
        guard let template = machine.state.sets.last(where: { $0.exerciseId == exerciseId }) else {
            return false
        }
        let result = machine.dispatch(.addSet(exerciseId: exerciseId))
        guard case .success = result else {
            if case .failure(let reason, _) = result { errorMessage = reason }
            return false
        }
        do {
            _ = try sessionDAO.appendSet(
                sessionId: sessionId,
                exerciseId: exerciseId,
                plannedWeight: template.plannedWeight,
                plannedReps: template.plannedReps,
                plannedDuration: template.plannedDurationSec,
                setClass: template.setClass
            )
            reloadFSM()
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    /// Start-empty bootstrap: ad-hoc sessions materialise zero rows and BR-004's
    /// [+] needs a template row, so the very first row is appended blank and
    /// opened in the edit sheet for its values. Values arrive through the sheet
    /// (editAndAccept), so INV-W2's actuals-iff-logged shape holds.
    @discardableResult
    public func addFirstSet(exerciseId: String) -> Bool {
        guard let sessionId, snapshot.sets.isEmpty else { return addSet(exerciseId: exerciseId) }
        guard let exercise = try? exerciseDAO.getById(exerciseId) else { return false }
        do {
            let newId = try sessionDAO.appendSet(
                sessionId: sessionId,
                exerciseId: exerciseId,
                plannedWeight: nil, plannedReps: nil, plannedDuration: nil,
                setClass: .work
            )
            exercisesById[exerciseId] = exercise
            reloadFSM()
            openEdit(setId: newId)
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    // MARK: Rest controls (SC-rest §4)

    /// Skip (BR-003): instant cancel/dismiss, no cue; skipping the latched
    /// final-set run morphs to the finish panel (§2b).
    public func skipRest() {
        route(restCycle.dispatch(.skip(at: Date())))
    }

    /// One-off ±15s stepper (BR-002): accumulates on the running timer, never
    /// persisted anywhere (INV-T2).
    public func adjustRest(delta: Int) {
        route(restCycle.dispatch(.adjustSec(delta: delta, at: Date())))
    }

    /// The view's heartbeat: natural-expiry detection (BR-007/BR-008). Cheap
    /// no-op outside a live run; expiry dispatches exactly one cue (INV-T3).
    public func restTick(now: Date) {
        guard case .restRunning = restCycle.state, restRemainingSec(at: now) <= 0 else { return }
        route(restCycle.dispatch(.expireNaturally(at: now)))
    }

    /// Foreground / re-presentation recompute (BR-007): remaining is recomputed
    /// from the run's timestamps — the timer survives backgrounding because it
    /// was never a tick counter. A killed process re-attaches in noRest.
    public func sceneBecameActive(now: Date = Date()) {
        guard case .restRunning = restCycle.state else { return }
        route(restCycle.dispatch(.backgrounded(at: now)))
    }

    // MARK: Finish (BR-008 / INV-W8)

    /// The finish CTA: stamp `endedAt` exactly once, then surface the
    /// plan-vs-actual summary.
    @discardableResult
    public func finish() -> Bool {
        guard var machine = fsm, let sessionId else { return false }
        let result = machine.dispatch(.finishSession)
        guard case .success = result else {
            if case .failure(let reason, _) = result { errorMessage = reason }
            return false
        }
        do {
            let endedAt = machine.state.finishedAt ?? Date()
            try sessionDAO.finishSession(sessionId: sessionId, at: endedAt)
            fsm = machine
            snapshot = machine.state
            // #35: stall-chain evaluation on the finished session (SC-progression
            // BR-012). Runs AFTER endedAt lands so the session counts as completed
            // history; the banner itself fires per NEXT materialization (BR-013).
            progression.onSessionFinished(sessionId: sessionId)
            buildSummary(sessionId: sessionId, endedAt: endedAt)
            // The session surface is terminal (§2b): the rest cycle has nothing
            // left to run — drop it rather than let a stale run tick on.
            restCycle = RestCycle()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    // MARK: Internals

    /// planned→completed/failed (+BR-006 corrections) share one write path:
    /// dispatch → persist via the seam-2 adapter → cold re-read → rest feed.
    private func dispatchTerminal(_ action: FsmAction, requestsRest: Bool = true) -> Bool {
        guard var machine = fsm, let setId = actionSetId(action) else { return false }
        let result = machine.dispatch(action)
        guard case .success = result else {
            if case .failure(let reason, _) = result { errorMessage = reason }
            return false
        }
        do {
            if let post = machine.state.sets.first(where: { $0.id == setId }) {
                switch action {
                case .editCompleted, .editFailed:
                    // INV-W6: completedAt untouched — nil leaves it intact.
                    try sessionDAO.updateSetStatus(
                        setId: setId, status: post.status,
                        actualWeight: post.actualWeight, actualReps: post.actualReps,
                        actualDuration: post.actualDurationSec, completedAt: nil
                    )
                default:
                    try sessionDAO.updateSetStatus(
                        setId: setId, status: post.status,
                        actualWeight: post.actualWeight, actualReps: post.actualReps,
                        actualDuration: post.actualDurationSec, completedAt: post.completedAt
                    )
                }
                // BR-003: a terminal transition FROM PLANNED (accept /
                // editAndAccept / fail) closes the undo window; BR-006
                // corrections are not such transitions (the FSM's editTerminal
                // leaves the window untouched — mirror it exactly).
                switch action {
                case .accept, .editAndAccept, .fail:
                    if undoableDrop != nil { undoableDrop?.available = false }
                default:
                    break
                }
                reloadFSM()
                // #36: PR evaluation rides AFTER the committed FSM transition —
                // a post-commit witness (SC-cues BR-011), completed work sets
                // only (SC-prs BR-001). Corrections re-derive the record book.
                evaluatePRs(action: action, post: post)
                // #40: the set-lifecycle witness (SC-cues §3a). Rides AFTER the
                // PR evaluation so a fired celebration subsumes the completion
                // tick (BR-008 natural order); the engine's per-set budget gate
                // does the suppressing, never this caller.
                dispatchSetWitness(action: action, post: post)
                if requestsRest {
                    startRest(for: post, at: Date())
                }
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    /// #36 — SC-prs seam, driven after every lawful terminal dispatch:
    ///   accept / editAndAccept → live PR evaluation on the completed set
    ///     (BR-002/BR-006; first-touch silent, failed/dropped/warmup never —
    ///     the engine gates them, BR-001);
    ///   editCompleted → re-derive that exercise's record book (BR-007);
    ///   fail / editFailed / drop / undoDrop / addSet / finish → nothing
    ///     (failed sets record actuals but never write PRs, SC-workout-logging
    ///     BR-002 downstream note; drops carry no actuals at all).
    /// Errors are swallowed by RecordsModel — the ✓ path already committed.
    private func evaluatePRs(action: FsmAction, post: SetSnapshot) {
        switch action {
        case .accept, .editAndAccept:
            guard post.status == .completed else { return }
            records.setCompleted(setId: post.id)
        case .editCompleted:
            records.rederive(exerciseId: post.exerciseId)
        case .fail, .editFailed, .drop, .undoDrop, .addSet, .finishSession:
            break
        }
    }

    /// #40 — SC-cues §3a set-lifecycle witnesses, dispatched post-commit
    /// (BR-011: cues never interpose on the ✓ path):
    ///   accept / editAndAccept → cue.set.completed (success haptic — unless
    ///     the celebration already subsumed it, BR-008 engine gate);
    ///   fail → cue.set.failed (nudge haptic, BR-002 records actuals);
    ///   corrections (BR-006), addSet, finish → nothing (no lifecycle change
    ///     to witness); drop/undo witness separately below (BR-009).
    private func dispatchSetWitness(action: FsmAction, post: SetSnapshot) {
        switch action {
        case .accept, .editAndAccept:
            cueChannel.dispatch(MooreCues.CueEvent(name: .setCompleted, at: Date(), setId: post.id))
        case .fail:
            cueChannel.dispatch(MooreCues.CueEvent(name: .setFailed, at: Date(), setId: post.id))
        case .editCompleted, .editFailed, .addSet, .finishSession, .drop, .undoDrop:
            break
        }
    }

    /// SC-rest seam: resolve the four-level hierarchy AT THE LOG MOMENT for the
    /// logged set's exercise (BR-001/INV-T1) and start the run. The final set's
    /// rest starts exactly like every other set (BR-006/INV-T4) — only its end
    /// routes through the §2b morph (latched via allSetsTerminal).
    private func startRest(for set: SetSnapshot, at date: Date) {
        let exercise = exercisesById[set.exerciseId]
        let resolution = RestResolver.resolve(
            perSetSec: perSetRestSec[set.id] ?? nil,
            perExerciseSec: exercise?.defaultRestSec,
            perRoutineSec: routineRestSec,
            categoryIsCompound: isCompound(exercise),
            settings: restSettings
        )
        let allTerminal = snapshot.allSetsTerminal
        let action: RestAction = set.status == .failed
            ? .setFailed(resolution: resolution, allSetsTerminal: allTerminal, at: date)
            : .setCompleted(resolution: resolution, allSetsTerminal: allTerminal, at: date)
        route(restCycle.dispatch(action))
    }

    /// Level-4 bucket (#9 resolution: one axis — category). The schema models
    /// muscle-group categories (SC-exercises §3b), not a compound flag, so the
    /// split is this deterministic map; duration-metric exercises always ride
    /// the isolation default (#9: rest isn't load-limited for them).
    private func isCompound(_ exercise: Exercise?) -> Bool {
        guard let exercise else { return false }
        if exercise.defaultMetric == .duration { return false }
        switch exercise.category {
        case .chest, .back, .shoulders, .quads, .hamstrings, .glutes, .fullBody:
            return true
        case .biceps, .triceps, .forearms, .core, .calves, .cardio, .other:
            return false
        }
    }

    private func showsPlatePreview(_ exerciseId: String) -> Bool {
        exercisesById[exerciseId]?.equipment == .barbell
    }

    private func actionSetId(_ action: FsmAction) -> String? {
        switch action {
        case .accept(let id), .editAndAccept(let id, _, _, _), .fail(let id, _, _, _),
             .editCompleted(let id, _, _, _), .editFailed(let id, _, _, _),
             .drop(let id), .undoDrop(let id):
            return id
        case .addSet, .finishSession:
            return nil
        }
    }

    /// Cold re-read (doctrine #9 r4): state recomputed from rows after every
    /// persisted transition. The undo window lives above this re-read (§8).
    private func reloadFSM() {
        guard let sessionId, let reloaded = try? sessionDAO.fetchSessionState(sessionId: sessionId) else { return }
        fsm = reloaded
        snapshot = reloaded.state
    }

    private func loadExercises() {
        var cache: [String: Exercise] = [:]
        for exerciseId in Set(snapshot.sets.map(\.exerciseId)) {
            if let exercise = try? exerciseDAO.getById(exerciseId) {
                cache[exerciseId] = exercise
            }
        }
        exercisesById = cache
    }

    /// Level-1 mapping: planned_set.restDurationSec → materialised rows. The
    /// copy is positional per exercise (materialisation preserves sortOrder),
    /// so the nth session row for exercise E carries the nth planned override;
    /// [+] rows beyond the plan inherit nil (walk on, BR-001). #35: warm-up
    /// rows are derived rows, not blueprint rows — they never consume an
    /// override slot (the positional copy stays aligned on the work rows).
    private func loadPerSetRestOverrides() {
        perSetRestSec = [:]
        guard let routineId else { return }
        guard let overrides = try? dbQueue.read({ db in
            try Row.fetchAll(db, sql: """
                SELECT exerciseId, restDurationSec FROM planned_set
                WHERE routineId = ? AND deletedAt IS NULL
                ORDER BY sortOrder
                """, arguments: [routineId])
        }) else { return }
        var queues: [String: [Int?]] = [:]
        for row in overrides {
            let exerciseId: String = row["exerciseId"]
            let restSec: Int? = row["restDurationSec"]
            queues[exerciseId, default: []].append(restSec)
        }
        for set in snapshot.sets where (set.setClass ?? .work) == .work {
            var queue = queues[set.exerciseId] ?? []
            perSetRestSec[set.id] = queue.isEmpty ? nil : queue.removeFirst()
            queues[set.exerciseId] = queue
        }
    }

    private func loadSettings() {
        restSettings = (try? restSettingsDAO.fetch()) ?? .default
        weightUnit = (try? settingsDAO.fetchSettings().weightUnit) ?? .kg
    }

    private func buildSummary(sessionId: String, endedAt: Date) {
        let sets = snapshot.sets
        let completed = sets.filter { $0.status == .completed }
        let volume = completed
            .filter { ($0.setClass ?? .work) == .work }
            .reduce(0.0) { $0 + ($1.actualWeight ?? 0) * Double($1.actualReps ?? 0) }
        summary = SessionSummary(
            routineName: routineName,
            startedAt: sessionStartedAt ?? endedAt,
            endedAt: endedAt,
            setCount: sets.count,
            setsDone: completed.count,
            setsFailed: sets.filter { $0.status == .failed }.count,
            setsDropped: sets.filter { $0.status == .dropped }.count,
            exerciseCount: Set(sets.map(\.exerciseId)).count,
            volumeKg: SettingsEngine.roundDisplay(volume),
            rows: sets.map { set in
                SessionSummaryRow(
                    id: set.id,
                    exerciseName: exerciseName(set.exerciseId),
                    status: set.status,
                    plannedText: plannedText(for: set),
                    actualText: actualText(for: set)
                )
            },
            // #36: the Summary celebrates the day (SC-prs BR-010) — render-time
            // PR read (INV-PR5), precedence-ordered, escalation in the view.
            prCards: records.summaryCards(sessionId: sessionId)
        )
    }

    private func route(_ cue: MooreRest.CueEvent?) {
        guard let cue else { return }
        cueChannel.dispatch(cue)
    }
}
