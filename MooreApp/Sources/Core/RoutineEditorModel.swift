// Ticket #33 — routine create/edit sheet model. Wraps the existing
// RoutineEditorBuffer (SC-routines §2a: pure in-progress buffer whose
// applyChanges() writes through RoutineDAO in one transaction). This class is
// presentation glue only: it exposes the buffer to SwiftUI, forwards editor
// gestures to the buffer's mutations, and resolves exercise names via
// ExerciseDAO for the set rows. No business logic is reimplemented.
//
// Foundation-only (@Observable, no SwiftUI) so it parses/verifies off-Mac.

import Foundation
import Observation
import MooreRoutines
import MooreExercises

@Observable
public final class RoutineEditorModel {
    /// The working buffer (name + set drafts). `buffer.routineId == nil` ⇔ creating.
    public var buffer: RoutineEditorBuffer
    /// Presents the exercise picker sheet (SC-exercises §2b).
    public var showingPicker = false
    /// Last save error, surfaced inline.
    public private(set) var saveError: String?

    private let routineDAO: RoutineDAO
    private let exerciseDAO: ExerciseDAO

    /// Creating a new routine (empty buffer).
    public init(routineDAO: RoutineDAO, exerciseDAO: ExerciseDAO) {
        self.routineDAO = routineDAO
        self.exerciseDAO = exerciseDAO
        self.buffer = RoutineEditorBuffer()
    }

    /// Editing an existing routine (buffer loaded from the routine + its live sets).
    public init(routineDAO: RoutineDAO, exerciseDAO: ExerciseDAO, routine: Routine, sets: [PlannedSet]) {
        self.routineDAO = routineDAO
        self.exerciseDAO = exerciseDAO
        self.buffer = RoutineEditorBuffer(routine: routine, sets: sets)
    }

    public var isNew: Bool { buffer.routineId == nil }

    /// Save requires a non-blank name (voice: no error toast — the CTA disables).
    public var canSave: Bool {
        !buffer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the routine currently has zero exercises — Start would be disabled
    /// on Home (BR-001); the editor shows the startDisabled hint copy.
    public var hasNoExercises: Bool { buffer.drafts.isEmpty }

    // MARK: Editor gestures → buffer mutations

    public func addExercise(_ exerciseId: String) {
        buffer.addExercise(exerciseId)
    }

    public func addSet(forExercise exerciseId: String) {
        buffer.addSet(forExercise: exerciseId)
    }

    public func updateSet(id: String, _ mutate: (inout EditableSetDraft) -> Void) {
        buffer.updateSet(id: id, mutate)
    }

    public func removeSet(id: String) {
        buffer.removeSet(id: id)
    }

    public func moveSet(from source: Int, to destination: Int) {
        buffer.moveSet(from: source, to: destination)
    }

    // MARK: Exercise resolution (read-only, for row labels)

    public func exercise(for exerciseId: String) -> Exercise? {
        try? exerciseDAO.getById(exerciseId)
    }

    /// Distinct exercises in the buffer, in first-appearance order (group headers).
    public var exercisesInBuffer: [Exercise] {
        var seen = Set<String>()
        var result: [Exercise] = []
        for draft in buffer.drafts where !seen.contains(draft.exerciseId) {
            seen.insert(draft.exerciseId)
            if let exercise = exercise(for: draft.exerciseId) {
                result.append(exercise)
            }
        }
        return result
    }

    // MARK: Persist

    /// applyChanges(): create → RoutineDAO.create; edit → RoutineDAO.update —
    /// one transaction either way (SC-routines V1/V2). Returns success.
    @discardableResult
    public func save() -> Bool {
        guard canSave else { return false }
        do {
            _ = try buffer.applyChanges(using: routineDAO)
            saveError = nil
            return true
        } catch {
            saveError = "\(error)"
            return false
        }
    }
}
