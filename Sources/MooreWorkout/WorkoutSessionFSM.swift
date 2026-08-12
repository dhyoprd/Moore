// contractId: SC-workout-logging @1.0.0
// Pure value-type state machine for the Active Workout money screen (§2).
// Foundation only — no GRDB, no SwiftUI, no Apple imports beyond Foundation.
// Learning time is deterministic: replaying a fixture's action list from a
// materialised snapshot must produce the same state every run.
//
// Illegal actions (§2a's `—` cells) return `.failure` with state unchanged and
// zero cues — the mis-tap-proof guarantee (BR-005) is structural, not hopeful.

import Foundation

public struct WorkoutSessionFSM {

    // MARK: - Internal state

    private var snapshot: StateSnapshot
    /// Index into `snapshot.sets` by set id (rebuilt on addSet).
    private var setIndex: [String: Int]
    /// Supports INV-W4's exactly-once finish morph.
    private var finishMorphEmitted: Bool
    private var clock: () -> Date

    // MARK: - Init

    /// Cold-start from already-materialised rows (§5: `readModel()`'s in-memory form).
    public init(sessionId: String, sets: [SetSnapshot], clock: @escaping () -> Date = Date.init) {
        let sorted = sets.sorted { $0.sortOrder < $1.sortOrder }
        var snap = StateSnapshot(sessionId: sessionId, sets: sorted)
        snap.nextIncompleteSetId = sorted.first(where: { !$0.status.isTerminal })?.id
        snap.finishRequested = snap.allSetsTerminal
        snap.overlayState = snap.allSetsTerminal ? .finishRequested : .idle
        self.snapshot = snap
        self.setIndex = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1.id, $0) })
        self.finishMorphEmitted = snap.allSetsTerminal
        self.clock = clock
    }

    // MARK: - Read seam (§5)

    public var state: StateSnapshot { snapshot }

    // MARK: - Dispatch (§5's single entry point)

    @discardableResult
    public mutating func dispatch(_ action: FsmAction) -> TransitionResult {
        switch action {
        case .accept(let setId):
            return transitionFromPlanned(setId: setId, actionName: "accept") { set in
                // BR-001: field-copy, whichever planned fields are non-NULL.
                set.actualWeight = set.plannedWeight
                set.actualReps = set.plannedReps
                set.actualDurationSec = set.plannedDurationSec
            }
        case .editAndAccept(let setId, let weight, let reps, let durationSec):
            return transitionFromPlanned(setId: setId, actionName: "editAndAccept") { set in
                // BR-001 edited variant: user-adjusted values into actualX; plannedX untouched.
                set.actualWeight = weight
                set.actualReps = reps
                set.actualDurationSec = durationSec
            }
        case .fail(let setId, let weight, let reps, let durationSec):
            return transitionFromPlanned(setId: setId, actionName: "fail", terminal: .failed) { set in
                // BR-002: actuals are mandatory and recorded explicitly.
                set.actualWeight = weight
                set.actualReps = reps
                set.actualDurationSec = durationSec
            }
        case .editCompleted(let setId, let weight, let reps, let durationSec):
            return editTerminal(setId: setId, required: .completed, actionName: "editCompleted", weight: weight, reps: reps, durationSec: durationSec)
        case .editFailed(let setId, let weight, let reps, let durationSec):
            return editTerminal(setId: setId, required: .failed, actionName: "editFailed", weight: weight, reps: reps, durationSec: durationSec)
        case .drop(let setId):
            return dropSet(setId)
        case .undoDrop(let setId):
            return undoDropSet(setId)
        case .addSet(let exerciseId):
            return addSetRow(exerciseId)
        case .finishSession:
            return finish()
        }
    }

    // MARK: - planned → completed/failed (BR-001, BR-002)

    private mutating func transitionFromPlanned(
        setId: String,
        actionName: String,
        terminal: SetStatus = .completed,
        applyActuals: (inout SetSnapshot) -> Void
    ) -> TransitionResult {
        guard let i = setIndex[setId] else {
            return .failure(reason: "unknown set \(setId)", action: actionName)
        }
        guard snapshot.sets[i].status == .planned else {
            return .failure(reason: "set is \(snapshot.sets[i].status.rawValue), not planned", action: actionName)
        }

        applyActuals(&snapshot.sets[i])
        snapshot.sets[i].status = terminal
        snapshot.sets[i].completedAt = clock()

        // BR-003: any terminal transition closes the outstanding drop-undo window.
        if snapshot.undoableDrop != nil { snapshot.undoableDrop?.available = false }

        snapshot.lastCompletedSetId = setId
        snapshot.nextIncompleteSetId = snapshot.sets.first(where: { !$0.status.isTerminal })?.id

        var cues: [CueEmission] = [terminal == .completed ? .setCompleted : .setFailed]

        if snapshot.allSetsTerminal {
            // BR-008: finish-morph takes over; rest is NOT requested (nothing to rest for).
            snapshot.overlayState = .finishRequested
            snapshot.finishRequested = true
            snapshot.restRequested = false
            if !finishMorphEmitted {
                cues.append(.finishMorph)   // INV-W4: exactly once per session.
                finishMorphEmitted = true
            }
        } else {
            // §2b: request rest; #23's layer owns everything after this flag.
            snapshot.overlayState = .restRequested
            snapshot.restRequested = true
        }
        return .success(emitted: cues)
    }

    // MARK: - edit-after-complete (BR-006)

    private mutating func editTerminal(
        setId: String,
        required: SetStatus,
        actionName: String,
        weight: Double?, reps: Int?, durationSec: Int?
    ) -> TransitionResult {
        guard let i = setIndex[setId] else {
            return .failure(reason: "unknown set \(setId)", action: actionName)
        }
        guard snapshot.sets[i].status == required else {
            return .failure(reason: "set is \(snapshot.sets[i].status.rawValue), not \(required.rawValue)", action: actionName)
        }
        // Overwrite actuals in place. completedAt intact (INV-W6). No rest request,
        // no cue re-emission — post-completion edits are corrections, not events.
        snapshot.sets[i].actualWeight = weight
        snapshot.sets[i].actualReps = reps
        snapshot.sets[i].actualDurationSec = durationSec
        return .success(emitted: [])
    }

    // MARK: - drop / undo (BR-003)

    private mutating func dropSet(_ setId: String) -> TransitionResult {
        guard let i = setIndex[setId] else {
            return .failure(reason: "unknown set \(setId)", action: "drop")
        }
        guard snapshot.sets[i].status == .planned else {
            return .failure(reason: "set is \(snapshot.sets[i].status.rawValue), not planned", action: "drop")
        }
        snapshot.sets[i].status = .dropped
        // Dropped sets never request rest (INV-W5 / BR-008); overlay back to idle
        // unless finish-morph now applies (this drop may have been the last planned set).
        snapshot.restRequested = false
        snapshot.lastCompletedSetId = nil
        snapshot.undoableDrop = UndoableDrop(setId: setId, available: true)
        snapshot.nextIncompleteSetId = snapshot.sets.first(where: { !$0.status.isTerminal })?.id

        var cues: [CueEmission] = [.setDropped]
        if snapshot.allSetsTerminal {
            snapshot.overlayState = .finishRequested
            snapshot.finishRequested = true
            if !finishMorphEmitted {
                cues.append(.finishMorph)
                finishMorphEmitted = true
            }
        } else {
            snapshot.overlayState = .idle
        }
        return .success(emitted: cues)
    }

    private mutating func undoDropSet(_ setId: String) -> TransitionResult {
        guard let i = setIndex[setId] else {
            return .failure(reason: "unknown set \(setId)", action: "undoDrop")
        }
        guard snapshot.sets[i].status == .dropped else {
            return .failure(reason: "set is \(snapshot.sets[i].status.rawValue), not dropped", action: "undoDrop")
        }
        guard let undo = snapshot.undoableDrop, undo.setId == setId, undo.available else {
            // BR-003: window closed by the next logged set — refused, nothing changes.
            return .failure(reason: "undo window closed", action: "undoDrop")
        }
        snapshot.sets[i].status = .planned   // actualX untouched — they're NULL (INV-W2)
        snapshot.undoableDrop = nil
        snapshot.restRequested = false
        snapshot.nextIncompleteSetId = snapshot.sets.first(where: { !$0.status.isTerminal })?.id
        snapshot.finishRequested = false
        snapshot.overlayState = .idle
        return .success(emitted: [])
    }

    // MARK: - add-set (BR-004)

    private mutating func addSetRow(_ exerciseId: String) -> TransitionResult {
        guard let template = snapshot.sets.last(where: { $0.exerciseId == exerciseId }) else {
            return .failure(reason: "exercise \(exerciseId) has no row in this session", action: "addSet")
        }
        let newId = UUID().uuidString.lowercased()
        let row = SetSnapshot(
            id: newId,
            exerciseId: exerciseId,
            sortOrder: snapshot.sets.count,          // INV-W7: append at count
            status: .planned,
            plannedWeight: template.plannedWeight,   // pre-filled from last row
            plannedReps: template.plannedReps,
            plannedDurationSec: template.plannedDurationSec,
            setClass: template.setClass
        )
        snapshot.sets.append(row)
        setIndex[newId] = snapshot.sets.count - 1
        // BR-008's morph is an affordance, not a lock: appending a row returns the
        // session to a workable list.
        if snapshot.finishRequested {
            snapshot.finishRequested = false
            snapshot.overlayState = .idle
        }
        snapshot.nextIncompleteSetId = snapshot.sets.first(where: { !$0.status.isTerminal })?.id
        // Adding a set never requests rest.
        return .success(emitted: [])
    }

    // MARK: - finish (BR-008, INV-W8)

    private mutating func finish() -> TransitionResult {
        guard snapshot.finishedAt == nil else {
            return .failure(reason: "session already finished", action: "finishSession")
        }
        guard snapshot.allSetsTerminal else {
            return .failure(reason: "sets still non-terminal", action: "finishSession")
        }
        snapshot.finishedAt = clock()
        snapshot.overlayState = .finishRequested
        snapshot.finishRequested = true
        snapshot.restRequested = false
        return .success(emitted: [])
    }
}
