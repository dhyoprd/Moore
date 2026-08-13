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
import MooreProgression

@Observable
public final class RoutineEditorModel {
    /// The working buffer (name + set drafts). `buffer.routineId == nil` ⇔ creating.
    public var buffer: RoutineEditorBuffer
    /// Presents the exercise picker sheet (SC-exercises §2b).
    public var showingPicker = false
    /// Last save error, surfaced inline.
    public private(set) var saveError: String?

    /// #35: per-exercise scheme picker drafts (SC-progression BR-002). Buffered
    /// here and persisted on Save — Cancel never writes (editor semantics).
    public private(set) var pairSchemes: [String: Scheme] = [:]
    /// #35: per-exercise warm-up toggle drafts (SC-warmup BR-010).
    public private(set) var pairWarmup: [String: Bool] = [:]
    /// Scheme as loaded — change detection for BR-017's chain reset.
    private var originalPairSchemes: [String: Scheme] = [:]
    /// Blueprint weights as loaded, per exercise (frequency counts: reorder is
    /// NOT a weight edit) — BR-017 change detection.
    private var originalWeights: [String: [Double?: Int]] = [:]

    private let routineDAO: RoutineDAO
    private let exerciseDAO: ExerciseDAO
    private let progression: ProgressionModel?

    /// Creating a new routine (empty buffer).
    public init(routineDAO: RoutineDAO, exerciseDAO: ExerciseDAO, progression: ProgressionModel? = nil) {
        self.routineDAO = routineDAO
        self.exerciseDAO = exerciseDAO
        self.progression = progression
        self.buffer = RoutineEditorBuffer()
    }

    /// Editing an existing routine (buffer loaded from the routine + its live sets).
    public init(routineDAO: RoutineDAO, exerciseDAO: ExerciseDAO, progression: ProgressionModel?, routine: Routine, sets: [PlannedSet]) {
        self.routineDAO = routineDAO
        self.exerciseDAO = exerciseDAO
        self.progression = progression
        self.buffer = RoutineEditorBuffer(routine: routine, sets: sets)
        loadPairSettings(sets: sets)
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

    // MARK: #35 — per-pair progression surfaces (scheme + warmup + preview)

    public func scheme(for exerciseId: String) -> Scheme {
        pairSchemes[exerciseId] ?? .none
    }

    public func warmupEnabled(for exerciseId: String) -> Bool {
        pairWarmup[exerciseId] ?? false
    }

    public func setScheme(_ scheme: Scheme, forExercise exerciseId: String) {
        pairSchemes[exerciseId] = scheme
    }

    public func setWarmupEnabled(_ enabled: Bool, forExercise exerciseId: String) {
        pairWarmup[exerciseId] = enabled
    }

    /// Warm-up generation gates on the reps metric (SC-warmup BR-002); the
    /// toggle hides for duration-metric exercises where the gate can't pass.
    public func showsWarmupToggle(_ exerciseId: String) -> Bool {
        progression?.isRepsMetric(exerciseId) ?? true
    }

    /// The routine-preview "Next:" line for one exercise (BR-018).
    public func nextLine(for exerciseId: String) -> String? {
        guard let progression, let routineId = buffer.routineId else { return nil }
        return progression.nextLineText(routineId: routineId, exerciseId: exerciseId)
    }

    /// The routine-preview stall banner for one exercise (BR-013).
    public func stallBanner(for exerciseId: String) -> StallBanner? {
        guard let progression, let routineId = buffer.routineId else { return nil }
        return progression.previewBanner(routineId: routineId, exerciseId: exerciseId)
    }

    public func dismissStallBanner(for exerciseId: String) {
        guard let progression, let routineId = buffer.routineId else { return }
        progression.dismissPreviewBanner(routineId: routineId, exerciseId: exerciseId)
    }

    public func applyStallChoice(_ action: StallAction, forExercise exerciseId: String) {
        guard let progression, let routineId = buffer.routineId else { return }
        progression.applyStallChoice(action, routineId: routineId, exerciseId: exerciseId)
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

    /// Distinct exercise ids in the buffer, in first-appearance order.
    public var exerciseIdsInBuffer: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for draft in buffer.drafts where !seen.contains(draft.exerciseId) {
            seen.insert(draft.exerciseId)
            result.append(draft.exerciseId)
        }
        return result
    }

    // MARK: Persist

    /// applyChanges(): create → RoutineDAO.create; edit → RoutineDAO.update —
    /// one transaction either way (SC-routines V1/V2). Then (#35) persists the
    /// per-pair scheme/warmup settings with BR-017's chain reset. Returns success.
    @discardableResult
    public func save() -> Bool {
        guard canSave else { return false }
        let wasNew = isNew
        do {
            let routine = try buffer.applyChanges(using: routineDAO)
            persistPairSettings(routineId: routine.id, wasNew: wasNew)
            saveError = nil
            return true
        } catch {
            saveError = "\(error)"
            return false
        }
    }

    // MARK: Internals

    /// Load persisted scheme + warmup settings per exercise (edit mode only),
    /// plus the BR-017 change-detection baselines.
    private func loadPairSettings(sets: [PlannedSet]) {
        guard let progression, let routineId = buffer.routineId else { return }
        for exerciseId in exerciseIdsInBuffer {
            let settings = progression.pairSettings(routineId: routineId, exerciseId: exerciseId)
            pairSchemes[exerciseId] = settings.scheme
            pairWarmup[exerciseId] = settings.warmupEnabled
            originalPairSchemes[exerciseId] = settings.scheme
        }
        for set in sets where (set.setClass ?? .work) == .work {
            originalWeights[set.exerciseId, default: [:]][set.plannedWeight, default: 0] += 1
        }
    }

    /// #35 post-save: write every pair's scheme + warmup toggle through
    /// ProgressionModel (BR-002 defaults, BR-017 chain reset on scheme or
    /// blueprint-weight edits, hold-duration baseline capture).
    private func persistPairSettings(routineId: String, wasNew: Bool) {
        guard let progression else { return }
        let currentWeights = workWeightCounts()
        for exerciseId in exerciseIdsInBuffer {
            let weightChanged: Bool
            if wasNew {
                weightChanged = false   // no pre-existing chain to reset
            } else {
                weightChanged = currentWeights[exerciseId] != originalWeights[exerciseId]
            }
            let blueprintDuration = buffer.drafts.first { $0.exerciseId == exerciseId }?.plannedDuration
            progression.editorDidSavePair(
                routineId: routineId,
                exerciseId: exerciseId,
                scheme: scheme(for: exerciseId),
                warmupEnabled: warmupEnabled(for: exerciseId),
                chainReset: weightChanged,
                blueprintDurationSec: blueprintDuration
            )
        }
    }

    /// Frequency counts of the current work-class blueprint weights per
    /// exercise (order-independent: reordering never reads as a weight edit).
    private func workWeightCounts() -> [String: [Double?: Int]] {
        var counts: [String: [Double?: Int]] = [:]
        for draft in buffer.drafts where draft.setClass == .work {
            counts[draft.exerciseId, default: [:]][draft.plannedWeight, default: 0] += 1
        }
        return counts
    }
}
