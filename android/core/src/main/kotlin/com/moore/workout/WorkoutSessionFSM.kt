// contractId: SC-workout-logging @1.0.0
// Pure value-type state machine for the Active Workout money screen (§2).
// No persistence, no UI imports. Learning time is deterministic: replaying a
// fixture's action list from a materialised snapshot must produce the same
// state every run.
//
// Illegal actions (§2a's — cells) return Failure with state unchanged and
// zero cues — the mis-tap-proof guarantee (BR-005) is structural, not hopeful.
// Mechanical Kotlin port of Sources/MooreWorkout/WorkoutSessionFSM.swift.
// The clock supplies ISO-8601 UTC stamps (the storage format of completedAt).
package com.moore.workout

import com.moore.foundation.SetStatus
import java.time.Instant
import java.util.UUID

class WorkoutSessionFSM(
    sessionId: String,
    sets: List<SetSnapshot>,
    private val clock: () -> String = { Instant.now().toString() },
) {

    // MARK: - Internal state

    private var snapshot: StateSnapshot
    /// Index into snapshot.sets by set id (rebuilt on addSet).
    private val setIndex = HashMap<String, Int>()
    /// Supports INV-W4's exactly-once finish morph.
    private var finishMorphEmitted: Boolean

    init {
        /// Cold-start from already-materialised rows (§5: readModel()'s in-memory form).
        val sorted = sets.sortedBy { it.sortOrder }
        val snap = StateSnapshot(sessionId = sessionId, sets = sorted.toMutableList())
        snap.nextIncompleteSetId = sorted.firstOrNull { !it.status.isTerminal }?.id
        snap.finishRequested = snap.allSetsTerminal
        snap.overlayState = if (snap.allSetsTerminal) OverlayState.FINISH_REQUESTED else OverlayState.IDLE
        snapshot = snap
        sorted.forEachIndexed { i, s -> setIndex[s.id] = i }
        finishMorphEmitted = snap.allSetsTerminal
    }

    // MARK: - Read seam (§5)

    val state: StateSnapshot get() = snapshot

    // MARK: - Dispatch (§5's single entry point)

    fun dispatch(action: FsmAction): TransitionResult {
        return when (action) {
            is FsmAction.Accept -> transitionFromPlanned(action.setId, "accept") { set ->
                // BR-001: field-copy, whichever planned fields are non-NULL.
                set.actualWeight = set.plannedWeight
                set.actualReps = set.plannedReps
                set.actualDurationSec = set.plannedDurationSec
            }
            is FsmAction.EditAndAccept -> transitionFromPlanned(action.setId, "editAndAccept") { set ->
                // BR-001 edited variant: user-adjusted values into actualX; plannedX untouched.
                set.actualWeight = action.weight
                set.actualReps = action.reps
                set.actualDurationSec = action.durationSec
            }
            is FsmAction.Fail -> transitionFromPlanned(action.setId, "fail", terminal = SetStatus.FAILED) { set ->
                // BR-002: actuals are mandatory and recorded explicitly.
                set.actualWeight = action.weight
                set.actualReps = action.reps
                set.actualDurationSec = action.durationSec
            }
            is FsmAction.EditCompleted -> editTerminal(action.setId, SetStatus.COMPLETED, "editCompleted", action.weight, action.reps, action.durationSec)
            is FsmAction.EditFailed -> editTerminal(action.setId, SetStatus.FAILED, "editFailed", action.weight, action.reps, action.durationSec)
            is FsmAction.Drop -> dropSet(action.setId)
            is FsmAction.UndoDrop -> undoDropSet(action.setId)
            is FsmAction.AddSet -> addSetRow(action.exerciseId)
            is FsmAction.FinishSession -> finish()
        }
    }

    // MARK: - planned → completed/failed (BR-001, BR-002)

    private fun transitionFromPlanned(
        setId: String,
        actionName: String,
        terminal: SetStatus = SetStatus.COMPLETED,
        applyActuals: (SetSnapshot) -> Unit,
    ): TransitionResult {
        val i = setIndex[setId]
            ?: return TransitionResult.Failure("unknown set $setId", actionName)
        if (snapshot.sets[i].status != SetStatus.PLANNED) {
            return TransitionResult.Failure("set is ${snapshot.sets[i].status.raw}, not planned", actionName)
        }

        applyActuals(snapshot.sets[i])
        snapshot.sets[i].status = terminal
        snapshot.sets[i].completedAt = clock()

        // BR-003: any terminal transition closes the outstanding drop-undo window.
        if (snapshot.undoableDrop != null) snapshot.undoableDrop?.available = false

        snapshot.lastCompletedSetId = setId
        snapshot.nextIncompleteSetId = snapshot.sets.firstOrNull { !it.status.isTerminal }?.id

        val cues = mutableListOf(if (terminal == SetStatus.COMPLETED) CueEmission.SET_COMPLETED else CueEmission.SET_FAILED)

        if (snapshot.allSetsTerminal) {
            // BR-008: finish-morph takes over; rest is NOT requested (nothing to rest for).
            snapshot.overlayState = OverlayState.FINISH_REQUESTED
            snapshot.finishRequested = true
            snapshot.restRequested = false
            if (!finishMorphEmitted) {
                cues.add(CueEmission.FINISH_MORPH)   // INV-W4: exactly once per session.
                finishMorphEmitted = true
            }
        } else {
            // §2b: request rest; #23's layer owns everything after this flag.
            snapshot.overlayState = OverlayState.REST_REQUESTED
            snapshot.restRequested = true
        }
        return TransitionResult.Success(cues)
    }

    // MARK: - edit-after-complete (BR-006)

    private fun editTerminal(
        setId: String,
        required: SetStatus,
        actionName: String,
        weight: Double?,
        reps: Int?,
        durationSec: Int?,
    ): TransitionResult {
        val i = setIndex[setId]
            ?: return TransitionResult.Failure("unknown set $setId", actionName)
        if (snapshot.sets[i].status != required) {
            return TransitionResult.Failure("set is ${snapshot.sets[i].status.raw}, not ${required.raw}", actionName)
        }
        // Overwrite actuals in place. completedAt intact (INV-W6). No rest request,
        // no cue re-emission — post-completion edits are corrections, not events.
        snapshot.sets[i].actualWeight = weight
        snapshot.sets[i].actualReps = reps
        snapshot.sets[i].actualDurationSec = durationSec
        return TransitionResult.Success(emptyList())
    }

    // MARK: - drop / undo (BR-003)

    private fun dropSet(setId: String): TransitionResult {
        val i = setIndex[setId]
            ?: return TransitionResult.Failure("unknown set $setId", "drop")
        if (snapshot.sets[i].status != SetStatus.PLANNED) {
            return TransitionResult.Failure("set is ${snapshot.sets[i].status.raw}, not planned", "drop")
        }
        snapshot.sets[i].status = SetStatus.DROPPED
        // Dropped sets never request rest (INV-W5 / BR-008); overlay back to idle
        // unless finish-morph now applies (this drop may have been the last planned set).
        snapshot.restRequested = false
        snapshot.lastCompletedSetId = null
        snapshot.undoableDrop = UndoableDrop(setId = setId, available = true)
        snapshot.nextIncompleteSetId = snapshot.sets.firstOrNull { !it.status.isTerminal }?.id

        val cues = mutableListOf(CueEmission.SET_DROPPED)
        if (snapshot.allSetsTerminal) {
            snapshot.overlayState = OverlayState.FINISH_REQUESTED
            snapshot.finishRequested = true
            if (!finishMorphEmitted) {
                cues.add(CueEmission.FINISH_MORPH)
                finishMorphEmitted = true
            }
        } else {
            snapshot.overlayState = OverlayState.IDLE
        }
        return TransitionResult.Success(cues)
    }

    private fun undoDropSet(setId: String): TransitionResult {
        val i = setIndex[setId]
            ?: return TransitionResult.Failure("unknown set $setId", "undoDrop")
        if (snapshot.sets[i].status != SetStatus.DROPPED) {
            return TransitionResult.Failure("set is ${snapshot.sets[i].status.raw}, not dropped", "undoDrop")
        }
        val undo = snapshot.undoableDrop
        if (undo == null || undo.setId != setId || !undo.available) {
            // BR-003: window closed by the next logged set — refused, nothing changes.
            return TransitionResult.Failure("undo window closed", "undoDrop")
        }
        snapshot.sets[i].status = SetStatus.PLANNED   // actualX untouched — they're NULL (INV-W2)
        snapshot.undoableDrop = null
        snapshot.restRequested = false
        snapshot.nextIncompleteSetId = snapshot.sets.firstOrNull { !it.status.isTerminal }?.id
        snapshot.finishRequested = false
        snapshot.overlayState = OverlayState.IDLE
        return TransitionResult.Success(emptyList())
    }

    // MARK: - add-set (BR-004)

    private fun addSetRow(exerciseId: String): TransitionResult {
        val template = snapshot.sets.lastOrNull { it.exerciseId == exerciseId }
            ?: return TransitionResult.Failure("exercise $exerciseId has no row in this session", "addSet")
        val newId = UUID.randomUUID().toString().lowercase()
        val row = SetSnapshot(
            id = newId,
            exerciseId = exerciseId,
            sortOrder = snapshot.sets.size,          // INV-W7: append at count
            status = SetStatus.PLANNED,
            plannedWeight = template.plannedWeight,   // pre-filled from last row
            plannedReps = template.plannedReps,
            plannedDurationSec = template.plannedDurationSec,
            setClass = template.setClass,
        )
        snapshot.sets.add(row)
        setIndex[newId] = snapshot.sets.size - 1
        // BR-008's morph is an affordance, not a lock: appending a row returns the
        // session to a workable list.
        if (snapshot.finishRequested) {
            snapshot.finishRequested = false
            snapshot.overlayState = OverlayState.IDLE
        }
        snapshot.nextIncompleteSetId = snapshot.sets.firstOrNull { !it.status.isTerminal }?.id
        // Adding a set never requests rest.
        return TransitionResult.Success(emptyList())
    }

    // MARK: - finish (BR-008, INV-W8)

    private fun finish(): TransitionResult {
        if (snapshot.finishedAt != null) {
            return TransitionResult.Failure("session already finished", "finishSession")
        }
        if (!snapshot.allSetsTerminal) {
            return TransitionResult.Failure("sets still non-terminal", "finishSession")
        }
        snapshot.finishedAt = clock()
        snapshot.overlayState = OverlayState.FINISH_REQUESTED
        snapshot.finishRequested = true
        snapshot.restRequested = false
        return TransitionResult.Success(emptyList())
    }
}
