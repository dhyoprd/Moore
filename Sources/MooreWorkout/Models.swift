// contractId: SC-workout-logging @1.0.0
// Domain models for the Active Workout FSM: set states, FsmAction, StateSnapshot.
// Platform-agnostic. No SwiftUI, no GRDB imports — persistence wiring lives in
// WorkoutSessionDAO.swift; this file stays a pure data contract readable by the
// Android port (§9).

import Foundation

/// Warm-up vs work classification (SC-foundation INV-6). Nil reads coalesce to `.work`.
/// Re-declared here (mirroring SC-routines) so MooreWorkout has no module dependency.
public enum SetClass: String, Codable, Sendable {
    case warmup
    case work
}

// MARK: - Per-set state (§2a)

/// Lifecycle of one `CompletedSet` row on the money screen. Mirrors the SQL CHECK
/// on `completed_set.status` (SC-foundation 0001). Replaces `RoutineLifecycle`'s
/// pattern: this one IS stored (it's the table's `status` column).
public enum SetStatus: String, Codable, Sendable, CaseIterable {
    case planned
    case completed
    case failed
    case dropped

    /// `completed` / `failed` / `dropped` are terminal (§2a, BR-008's finish check).
    public var isTerminal: Bool { self != .planned }
}

/// Session overlay state (§2b). This FSM owns only the transitions *into* these
/// states; the countdown / expiry / skip semantics are #23's layer (INV-W5).
public enum OverlayState: String, Codable, Sendable {
    case idle
    case restRequested
    case finishRequested
}

// MARK: - Cue emissions (§5 — emitted, never performed)

/// Cue descriptor handed to the cue dispatcher (#23 / #29). This layer imports no
/// haptic framework; it only names *what happened*, keyed by #10's canonical IDs.
public enum CueEmission: String, Codable, Sendable {
    case setCompleted = "cue.set.completed"
    case setFailed = "cue.set.failed"
    case setDropped = "cue.set.dropped"
    case finishMorph = "cue.finish.morph"
}

// MARK: - FsmAction (§2a actions, parameterised)

/// The single entry point for every user gesture on the money screen (§5).
/// No write path exists around the FSM.
public enum FsmAction: Codable, Sendable {
    /// ✓ tap on a `planned` row — BR-001's 1-tap field-copy (actualX = plannedX).
    case accept(setId: String)

    /// Sheet ✓ after adjusting values — BR-001's edited variant; `plannedX` untouched.
    /// Only non-nil parameters are written; nil leaves that actual NULL.
    case editAndAccept(setId: String, weight: Double?, reps: Int?, durationSec: Int?)

    /// Swipe-left Failed → sheet → user typed actuals → ✓ (BR-002).
    /// Actuals are mandatory: failing at 7 vs 4 carries opposite progression signals.
    case fail(setId: String, weight: Double?, reps: Int?, durationSec: Int?)

    /// Post-completion correction (BR-006). Overwrites actuals in place;
    /// never re-triggers rest, never re-stamps `completedAt` (INV-W6).
    case editCompleted(setId: String, weight: Double?, reps: Int?, durationSec: Int?)

    /// Correction on a `failed` set (BR-006's symmetric case). Stays `failed`.
    case editFailed(setId: String, weight: Double?, reps: Int?, durationSec: Int?)

    /// Swipe-left Drop set. Instant, from `planned` only; dropped sets never
    /// request rest (INV-W5). Opens the undo window (BR-003).
    case drop(setId: String)

    /// Undo the drop, lawful only until the next set is logged — any set, any
    /// exercise — with no timer (#10). Re-opens the row to `planned` (BR-003).
    case undoDrop(setId: String)

    /// `[+]` in an exercise-group header: appends a `planned` row pre-filled from
    /// that exercise's last row in the session (BR-004). Dropsets are emergent.
    case addSet(exerciseId: String)

    /// The one-tap Finish CTA in the `finishRequested` overlay (BR-008).
    /// Stamps `endedAt` exactly once (INV-W8).
    case finishSession
}

// MARK: - Transition result (§5)

/// What dispatch produced. Illegal actions (§2a's `—` cells) return
/// `.failure(reason)` with state unchanged and zero cues.
public enum TransitionResult: Equatable, Sendable {
    case success(emitted: [CueEmission])
    case failure(reason: String, action: String)
}

// MARK: - Snapshot types (`state: StateSnapshot`, §5)

/// One row of the money screen's flat list, derived from a `CompletedSet`.
public struct SetSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var exerciseId: String
    public var sortOrder: Int
    public var status: SetStatus
    public var plannedWeight: Double?
    public var plannedReps: Int?
    public var plannedDurationSec: Int?
    public var actualWeight: Double?
    public var actualReps: Int?
    public var actualDurationSec: Int?
    public var setClass: SetClass?
    public var completedAt: Date?
    /// Whether this row currently accepts the ✓ gesture (§2a: only `planned`).
    public var isActionable: Bool { status == .planned }

    public init(
        id: String, exerciseId: String, sortOrder: Int, status: SetStatus,
        plannedWeight: Double? = nil, plannedReps: Int? = nil, plannedDurationSec: Int? = nil,
        actualWeight: Double? = nil, actualReps: Int? = nil, actualDurationSec: Int? = nil,
        setClass: SetClass? = nil, completedAt: Date? = nil
    ) {
        self.id = id
        self.exerciseId = exerciseId
        self.sortOrder = sortOrder
        self.status = status
        self.plannedWeight = plannedWeight
        self.plannedReps = plannedReps
        self.plannedDurationSec = plannedDurationSec
        self.actualWeight = actualWeight
        self.actualReps = actualReps
        self.actualDurationSec = actualDurationSec
        self.setClass = setClass
        self.completedAt = completedAt
    }
}

/// The drop-undo affordance state (BR-003). `available` flips false the moment
/// any set goes terminal after the drop — the "until next set logged" rule.
public struct UndoableDrop: Codable, Equatable, Sendable {
    public var setId: String
    public var available: Bool

    public init(setId: String, available: Bool) {
        self.setId = setId
        self.available = available
    }
}

/// The FSM's observable, read-only snapshot (§5). The money screen renders only
/// this; cold renders rebuild it from SQLite via `readModel()` (INV-W5 / #9 r4).
public struct StateSnapshot: Codable, Equatable, Sendable {
    public var sessionId: String
    public var sets: [SetSnapshot]
    public var overlayState: OverlayState
    /// True only on the snapshot taken immediately after a set reached
    /// `completed`/`failed` from `planned` — the *entire* contract with #23 (INV-W5).
    public var restRequested: Bool
    public var lastCompletedSetId: String?
    /// First non-terminal row (INV-W1: derived, never an enforced cursor).
    public var nextIncompleteSetId: String?
    public var undoableDrop: UndoableDrop?
    public var finishRequested: Bool
    /// Set when `finishSession` has stamped `endedAt` (INV-W8).
    public var finishedAt: Date?

    public init(
        sessionId: String,
        sets: [SetSnapshot] = [],
        overlayState: OverlayState = .idle,
        restRequested: Bool = false,
        lastCompletedSetId: String? = nil,
        nextIncompleteSetId: String? = nil,
        undoableDrop: UndoableDrop? = nil,
        finishRequested: Bool = false,
        finishedAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.sets = sets
        self.overlayState = overlayState
        self.restRequested = restRequested
        self.lastCompletedSetId = lastCompletedSetId
        self.nextIncompleteSetId = nextIncompleteSetId
        self.undoableDrop = undoableDrop
        self.finishRequested = finishRequested
        self.finishedAt = finishedAt
    }

    /// Finish-morph trigger check (BR-008): every set terminal.
    public var allSetsTerminal: Bool {
        !sets.isEmpty && sets.allSatisfy { $0.status.isTerminal }
    }
}
