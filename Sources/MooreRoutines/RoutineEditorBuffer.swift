// contractId: SC-routines @1.0.0
// In-progress routine editor state (§2a). Pure struct: holds the working name + the
// working set list; `applyChanges()` writes back through RoutineDAO in one transaction
// (reorder / add / remove / change planned values — V2). No SwiftUI.

import Foundation

public struct RoutineEditorBuffer: Equatable, Sendable {
    /// The routine being edited. Nil = creating a new routine (applyChanges → create).
    public private(set) var routineId: String?
    public var name: String
    /// Working set list, in display order (index = sortOrder). May be empty (§2a draft
    /// is legal; such a routine has `startEnabled = false` per BR-001).
    public private(set) var drafts: [EditableSetDraft]

    /// Load an existing routine + its live sets into the buffer.
    public init(routine: Routine, sets: [PlannedSet]) {
        self.routineId = routine.id
        self.name = routine.name
        self.drafts = sets.map {
            EditableSetDraft(
                id: $0.id,
                exerciseId: $0.exerciseId,
                plannedWeight: $0.plannedWeight,
                plannedReps: $0.plannedReps,
                plannedDuration: $0.plannedDuration,
                setClass: $0.setClass ?? .work
            )
        }
    }

    /// Start a new empty routine buffer.
    public init(name: String = "") {
        self.routineId = nil
        self.name = name
        self.drafts = []
    }

    // MARK: - Mutations (editor gestures)

    /// Add an exercise (chosen via the SC-exercises picker) as one new set row at the
    /// end. The exercise's id is supplied by the picker's callback.
    public mutating func addExercise(_ exerciseId: String) {
        drafts.append(EditableSetDraft(id: Self.newId(), exerciseId: exerciseId))
    }

    /// Append another set row for an exercise already in the buffer (defaults copied
    /// from that exercise's last row, matching #7's add-set affordance).
    public mutating func addSet(forExercise exerciseId: String) {
        let template = drafts.last { $0.exerciseId == exerciseId }
        var row = EditableSetDraft(id: Self.newId(), exerciseId: exerciseId)
        if let template {
            row.plannedWeight = template.plannedWeight
            row.plannedReps = template.plannedReps
            row.plannedDuration = template.plannedDuration
            row.setClass = template.setClass
        }
        drafts.append(row)
    }

    /// Update a single row's planned values (weight / reps / duration / class).
    public mutating func updateSet(id: String, _ mutate: (inout EditableSetDraft) -> Void) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        mutate(&drafts[i])
    }

    /// Remove a set row.
    public mutating func removeSet(id: String) {
        drafts.removeAll { $0.id == id }
    }

    /// Move a set row (reorder). Indices are into the current `drafts` order.
    public mutating func moveSet(from source: Int, to destination: Int) {
        guard drafts.indices.contains(source), drafts.indices.contains(destination), source != destination else { return }
        let item = drafts.remove(at: source)
        drafts.insert(item, at: destination)
    }

    // MARK: - Persist

    /// Write the buffer back. New routine → `RoutineDAO.create`; existing → `update`
    /// (reorder / add / remove / change planned values in one transaction). Returns the
    /// persisted routine.
    @discardableResult
    public func applyChanges(using dao: RoutineDAO, folderId: String? = nil) throws -> Routine {
        if let routineId {
            return try dao.update(id: routineId, name: name, setDrafts: drafts)
        } else {
            return try dao.create(name: name, folderId: folderId, exerciseList: drafts)
        }
    }

    private static func newId() -> String {
        UUID().uuidString.lowercased()
    }
}
