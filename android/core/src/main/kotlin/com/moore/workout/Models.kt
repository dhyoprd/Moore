// contractId: SC-workout-logging @1.0.0
// Domain models for the Active Workout FSM: set states, FsmAction, StateSnapshot.
// Platform-agnostic. Mechanical Kotlin port of Sources/MooreWorkout/Models.swift.
package com.moore.workout

import com.moore.foundation.SetClass
import com.moore.foundation.SetStatus

// MARK: - Session overlay state (§2b)

/// Session overlay state (§2b). This FSM owns only the transitions into these
/// states; the countdown / expiry / skip semantics are #23's layer (INV-W5).
enum class OverlayState(val raw: String) {
    IDLE("idle"), REST_REQUESTED("restRequested"), FINISH_REQUESTED("finishRequested");
}

// MARK: - Cue emissions (§5 — emitted, never performed)

/// Cue descriptor handed to the cue dispatcher (#23 / #29). This layer names
/// only what happened, keyed by #10's canonical IDs.
enum class CueEmission(val raw: String) {
    SET_COMPLETED("cue.set.completed"),
    SET_FAILED("cue.set.failed"),
    SET_DROPPED("cue.set.dropped"),
    FINISH_MORPH("cue.finish.morph");
}

// MARK: - FsmAction (§2a actions, parameterised)

/// The single entry point for every user gesture on the money screen (§5).
/// No write path exists around the FSM.
sealed class FsmAction {
    /// ✓ tap on a planned row — BR-001's 1-tap field-copy (actualX = plannedX).
    data class Accept(val setId: String) : FsmAction()

    /// Sheet ✓ after adjusting values — BR-001's edited variant; plannedX untouched.
    /// Only non-null parameters are written; null leaves that actual NULL.
    data class EditAndAccept(val setId: String, val weight: Double?, val reps: Int?, val durationSec: Int?) : FsmAction()

    /// Swipe-left Failed → sheet → user typed actuals → ✓ (BR-002).
    data class Fail(val setId: String, val weight: Double?, val reps: Int?, val durationSec: Int?) : FsmAction()

    /// Post-completion correction (BR-006). Overwrites actuals in place;
    /// never re-triggers rest, never re-stamps completedAt (INV-W6).
    data class EditCompleted(val setId: String, val weight: Double?, val reps: Int?, val durationSec: Int?) : FsmAction()

    /// Correction on a failed set (BR-006's symmetric case). Stays failed.
    data class EditFailed(val setId: String, val weight: Double?, val reps: Int?, val durationSec: Int?) : FsmAction()

    /// Swipe-left Drop set. Instant, from planned only; dropped sets never
    /// request rest (INV-W5). Opens the undo window (BR-003).
    data class Drop(val setId: String) : FsmAction()

    /// Undo the drop, lawful only until the next set is logged — any set, any
    /// exercise — with no timer (#10). Re-opens the row to planned (BR-003).
    data class UndoDrop(val setId: String) : FsmAction()

    /// [+] in an exercise-group header: appends a planned row pre-filled from
    /// that exercise's last row in the session (BR-004). Dropsets are emergent.
    data class AddSet(val exerciseId: String) : FsmAction()

    /// The one-tap Finish CTA in the finishRequested overlay (BR-008).
    /// Stamps endedAt exactly once (INV-W8).
    object FinishSession : FsmAction()
}

// MARK: - Transition result (§5)

/// What dispatch produced. Illegal actions (§2a's — cells) return
/// Failure(reason) with state unchanged and zero cues.
sealed class TransitionResult {
    data class Success(val emitted: List<CueEmission>) : TransitionResult()
    data class Failure(val reason: String, val action: String) : TransitionResult()
}

// MARK: - Snapshot types (state: StateSnapshot, §5)

/// One row of the money screen's flat list, derived from a CompletedSet.
data class SetSnapshot(
    var id: String,
    var exerciseId: String,
    var sortOrder: Int,
    var status: SetStatus,
    var plannedWeight: Double? = null,
    var plannedReps: Int? = null,
    var plannedDurationSec: Int? = null,
    var actualWeight: Double? = null,
    var actualReps: Int? = null,
    var actualDurationSec: Int? = null,
    var setClass: SetClass? = null,
    var completedAt: String? = null,
) {
    /// Whether this row currently accepts the ✓ gesture (§2a: only planned).
    val isActionable: Boolean get() = status == SetStatus.PLANNED
}

/// The drop-undo affordance state (BR-003). `available` flips false the moment
/// any set goes terminal after the drop — the "until next set logged" rule.
data class UndoableDrop(
    var setId: String,
    var available: Boolean,
)

/// The FSM's observable, read-only snapshot (§5). The money screen renders only
/// this; cold renders rebuild it from SQLite via readModel() (INV-W5 / #9 r4).
data class StateSnapshot(
    var sessionId: String,
    var sets: MutableList<SetSnapshot> = mutableListOf(),
    var overlayState: OverlayState = OverlayState.IDLE,
    /// True only on the snapshot taken immediately after a set reached
    /// completed/failed from planned — the entire contract with #23 (INV-W5).
    var restRequested: Boolean = false,
    var lastCompletedSetId: String? = null,
    /// First non-terminal row (INV-W1: derived, never an enforced cursor).
    var nextIncompleteSetId: String? = null,
    var undoableDrop: UndoableDrop? = null,
    var finishRequested: Boolean = false,
    /// Set when finishSession has stamped endedAt (INV-W8).
    var finishedAt: String? = null,
) {
    /// Finish-morph trigger check (BR-008): every set terminal.
    val allSetsTerminal: Boolean
        get() = sets.isNotEmpty() && sets.all { it.status.isTerminal }
}
