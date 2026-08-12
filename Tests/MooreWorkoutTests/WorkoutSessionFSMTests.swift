// contractId: SC-workout-logging @1.0.0
// Seam-1 FSM unit tests — pure value-type transitions, no DB. The Node verifier
// (VerifyWorkoutFsm.mjs) covers seam-2 DB effects; these cover the Swift FSM's
// guard matrix directly (every §2a transition, legal and illegal).

import XCTest
@testable import MooreWorkout

final class WorkoutSessionFSMTests: XCTestCase {

    private func makeSet(id: String, weight: Double? = 60, reps: Int? = 8) -> SetSnapshot {
        SetSnapshot(
            id: id, exerciseId: "ex-bench", sortOrder: 0, status: .planned,
            plannedWeight: weight, plannedReps: reps
        )
    }

    private func makeFSM(setCount: Int = 2) -> WorkoutSessionFSM {
        let sets = (0..<setCount).map { i in
            SetSnapshot(
                id: "set-\(i)", exerciseId: "ex-bench", sortOrder: i, status: .planned,
                plannedWeight: 60, plannedReps: 8
            )
        }
        return WorkoutSessionFSM(sessionId: "sess-1", sets: sets)
    }

    // BR-001: 1-tap accept field-copies plannedX → actualX.
    func testAcceptFieldCopies() {
        var fsm = makeFSM()
        let result = fsm.dispatch(.accept(setId: "set-0"))
        XCTAssertEqual(result, .success(emitted: [.setCompleted]))
        let s = fsm.state.sets[0]
        XCTAssertEqual(s.status, .completed)
        XCTAssertEqual(s.actualWeight, 60)
        XCTAssertEqual(s.actualReps, 8)
        XCTAssertEqual(s.plannedWeight, 60)  // INV-W3: planned untouched
        XCTAssertNotNil(s.completedAt)
        XCTAssertTrue(fsm.state.restRequested)
        XCTAssertEqual(fsm.state.overlayState, .restRequested)
        XCTAssertEqual(fsm.state.lastCompletedSetId, "set-0")
        XCTAssertEqual(fsm.state.nextIncompleteSetId, "set-1")
    }

    // §2a illegal: no transition completed → planned (ticket AC: "no transitions
    // from completed back to planned").
    func testAcceptTwiceRefused() {
        var fsm = makeFSM()
        _ = fsm.dispatch(.accept(setId: "set-0"))
        let result = fsm.dispatch(.accept(setId: "set-0"))
        guard case .failure = result else { return XCTFail("second accept must fail") }
        XCTAssertEqual(fsm.state.sets[0].actualReps, 8)  // values intact
    }

    // BR-002: fail records actual reps explicitly.
    func testFailRecordsActuals() {
        var fsm = makeFSM(setCount: 1)
        let result = fsm.dispatch(.fail(setId: "set-0", weight: 60, reps: 7, durationSec: nil))
        XCTAssertEqual(result, .success(emitted: [.setFailed, .finishMorph]))  // sole set → terminal → morph
        let s = fsm.state.sets[0]
        XCTAssertEqual(s.status, .failed)
        XCTAssertEqual(s.actualReps, 7)
        XCTAssertTrue(fsm.state.finishRequested)
    }

    // BR-003: drop + undo while window open; closed by next logged set.
    func testDropUndoWindow() {
        var fsm = makeFSM()
        _ = fsm.dispatch(.drop(setId: "set-0"))
        XCTAssertEqual(fsm.state.sets[0].status, .dropped)
        XCTAssertFalse(fsm.state.restRequested)  // dropped never requests rest
        XCTAssertEqual(fsm.state.undoableDrop, UndoableDrop(setId: "set-0", available: true))

        _ = fsm.dispatch(.accept(setId: "set-1"))
        let refused = fsm.dispatch(.undoDrop(setId: "set-0"))
        guard case .failure = refused else { return XCTFail("undo after next set logged must fail") }
        XCTAssertEqual(fsm.state.sets[0].status, .dropped)
    }

    func testUndoRestoresWhenOpen() {
        var fsm = makeFSM()
        _ = fsm.dispatch(.drop(setId: "set-0"))
        let result = fsm.dispatch(.undoDrop(setId: "set-0"))
        XCTAssertEqual(result, .success(emitted: []))
        XCTAssertEqual(fsm.state.sets[0].status, .planned)
        XCTAssertNil(fsm.state.undoableDrop)
    }

    // BR-004: add-set prefilled from the exercise's last row.
    func testAddSetPrefills() {
        var fsm = makeFSM()
        let result = fsm.dispatch(.addSet(exerciseId: "ex-bench"))
        XCTAssertEqual(result, .success(emitted: []))
        let added = fsm.state.sets.last!
        XCTAssertEqual(added.sortOrder, 2)
        XCTAssertEqual(added.plannedWeight, 60)
        XCTAssertEqual(added.plannedReps, 8)
        XCTAssertNil(added.actualWeight)
        XCTAssertEqual(added.status, .planned)
    }

    // BR-006: edit-after-complete overwrites in place, restRequested NOT re-set,
    // completedAt untouched, no cue re-emission.
    func testEditCompletedNoRestRetrigger() {
        var fsm = makeFSM()
        _ = fsm.dispatch(.accept(setId: "set-0"))
        let stampBefore = fsm.state.sets[0].completedAt
        let result = fsm.dispatch(.editCompleted(setId: "set-0", weight: 60, reps: 10, durationSec: nil))
        XCTAssertEqual(result, .success(emitted: []))
        XCTAssertEqual(fsm.state.sets[0].actualReps, 10)
        XCTAssertEqual(fsm.state.sets[0].completedAt, stampBefore)  // INV-W6
    }

    // BR-007 / INV-W1: order-free accept (any row, any order) — superset emergence.
    func testOrderFreeAccepts() {
        var fsm = makeFSM(setCount: 1)
        _ = fsm.dispatch(.addSet(exerciseId: "ex-bench"))
        _ = fsm.dispatch(.addSet(exerciseId: "ex-bench"))
        _ = fsm.dispatch(.accept(setId: fsm.state.sets[2].id))
        _ = fsm.dispatch(.accept(setId: fsm.state.sets[0].id))
        _ = fsm.dispatch(.accept(setId: fsm.state.sets[1].id))
        XCTAssertTrue(fsm.state.allSetsTerminal)
        XCTAssertEqual(fsm.state.overlayState, .finishRequested)
    }

    // BR-008: finish morph fires exactly once even across multiple terminal transitions.
    func testFinishMorphEmittedOnce() {
        var fsm = makeFSM()
        _ = fsm.dispatch(.drop(setId: "set-0"))
        _ = fsm.dispatch(.accept(setId: "set-1"))
        let result = fsm.dispatch(.finishSession)
        XCTAssertEqual(result, .success(emitted: []))
        XCTAssertNotNil(fsm.state.finishedAt)
    }
}
