// contractId: SC-routines @1.0.0
// In-progress routine editor state (§2a). Pure value type: holds the working name
// + the working set list; applyChanges() writes back through RoutineDAO in one
// transaction (reorder / add / remove / change planned values — V2). No UI.
// Mechanical Kotlin port of Sources/MooreRoutines/RoutineEditorBuffer.swift.
package com.moore.routines

import com.moore.foundation.SetClass
import java.util.UUID

class RoutineEditorBuffer private constructor(
    /// The routine being edited. Null = creating a new routine (applyChanges → create).
    var routineId: String?,
    var name: String,
    /// Working set list, in display order (index = sortOrder). May be empty (§2a
    /// draft is legal; such a routine has startEnabled = false per BR-001).
    drafts: List<EditableSetDraft>,
) {
    private val _drafts = drafts.toMutableList()
    val drafts: List<EditableSetDraft> get() = _drafts

    /// Load an existing routine + its live sets into the buffer.
    constructor(routine: Routine, sets: List<PlannedSet>) : this(
        routineId = routine.id,
        name = routine.name,
        drafts = sets.map {
            EditableSetDraft(
                id = it.id,
                exerciseId = it.exerciseId,
                plannedWeight = it.plannedWeight,
                plannedReps = it.plannedReps,
                plannedDuration = it.plannedDuration,
                setClass = it.setClass ?: SetClass.WORK,
            )
        },
    )

    /// Start a new empty routine buffer.
    constructor(name: String = "") : this(routineId = null, name = name, drafts = emptyList())

    // MARK: - Mutations (editor gestures)

    /// Add an exercise (chosen via the SC-exercises picker) as one new set row
    /// at the end.
    fun addExercise(exerciseId: String) {
        _drafts.add(EditableSetDraft(id = newId(), exerciseId = exerciseId))
    }

    /// Append another set row for an exercise already in the buffer (defaults
    /// copied from that exercise's last row, matching #7's add-set affordance).
    /// (Swift label `addSet(forExercise:)`.)
    fun addSetForExercise(exerciseId: String) {
        val template = _drafts.lastOrNull { it.exerciseId == exerciseId }
        val row = EditableSetDraft(id = newId(), exerciseId = exerciseId)
        if (template != null) {
            row.plannedWeight = template.plannedWeight
            row.plannedReps = template.plannedReps
            row.plannedDuration = template.plannedDuration
            row.setClass = template.setClass
        }
        _drafts.add(row)
    }

    /// Update a single row's planned values (weight / reps / duration / class).
    fun updateSet(id: String, mutate: (EditableSetDraft) -> Unit) {
        val i = _drafts.indexOfFirst { it.id == id }
        if (i < 0) return
        mutate(_drafts[i])
    }

    /// Remove a set row.
    fun removeSet(id: String) {
        _drafts.removeAll { it.id == id }
    }

    /// Move a set row (reorder). Indices are into the current drafts order.
    /// (Swift labels `moveSet(from:to:)`.)
    fun moveSet(source: Int, destination: Int) {
        if (source !in _drafts.indices || destination !in _drafts.indices || source == destination) return
        val item = _drafts.removeAt(source)
        _drafts.add(destination, item)
    }

    // MARK: - Persist

    /// Write the buffer back. New routine → RoutineDAO.create; existing → update
    /// (reorder / add / remove / change planned values in one transaction).
    /// Returns the persisted routine.
    fun applyChanges(dao: RoutineDAO, folderId: String? = null): Routine {
        val routineId = this.routineId
        return if (routineId != null) {
            dao.update(id = routineId, name = name, setDrafts = _drafts.toList())
        } else {
            dao.create(name = name, folderId = folderId, exerciseList = _drafts.toList())
        }
    }

    private fun newId(): String = UUID.randomUUID().toString().lowercase()
}
