// Ticket #35 — Progression + warm-ups + stall surfaces. Foundation-only
// (@Observable, no SwiftUI) so it parses/verifies off-Mac; the SwiftUI layer
// in Views/ binds to this surface and stays thin.
//
// Architecture: this class DRIVES the frozen pure engines — it never
// reimplements them:
//   • ProgressionEngine (SC-progression@1.0.0): suggest / onSessionFinished /
//     applyStallChoice / resetChainOnEdit — ALL scheme math, stall counters,
//     deload flow, and rounding live there.
//   • ProgressionDAO: scheme-row persistence, BR-004 history window, category
//     seam (BR-009), work-class set reads.
//   • WarmupRamp + WarmupMaterialize (SC-warmup@1.0.0): ramp derivation +
//     materialization-time write pass (nearestDown rounding, collapse rules).
//   • WarmupDAO: the warmupEnabled gate read that never auto-creates rows
//     (BR-010 zero-surprise default).
//
// Surfaces (SC-progression BR-018): silent plannedX stamping at materialization
// (the planned row text IS the suggestion — no chips on the money screen),
// one-line "Next:" routine-preview text, a non-modal tap-to-apply stall banner,
// per-pair scheme + warmup editing, and chain reset on blueprint edits.

import Foundation
import Observation
import GRDB
import MooreProgression
import MooreWarmup
import MooreWorkout
import MooreExercises
import MooreRoutines
import MooreSettings

// MARK: - Stall banner surface (SC-progression BR-013)

/// One non-blocking stall banner. Non-modal by construction: it renders inline
/// at the top of an exercise group, never intercepts the per-set ✓, and its
/// choices are tap-to-apply (Deload is NEVER automatic — BR-014).
public struct StallBanner: Identifiable, Equatable {
    public let routineId: String
    public let exerciseId: String
    public let exerciseName: String
    /// progression.banner.stall copy, resolved (SC-progression §5).
    public let copy: String
    public let stallCount: Int
    /// BR-013: the Deload CTA renders only when a weight exists for the pair.
    public let deloadAvailable: Bool

    public init(
        routineId: String, exerciseId: String, exerciseName: String,
        copy: String, stallCount: Int, deloadAvailable: Bool
    ) {
        self.routineId = routineId
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.copy = copy
        self.stallCount = stallCount
        self.deloadAvailable = deloadAvailable
    }

    public var id: String { routineId + "/" + exerciseId }
}

// MARK: - Per-pair editor settings (routine-editor surface)

/// The routine-editor row surface per (routineId, exerciseId) pair: scheme
/// picker value + warm-up toggle (SC-progression BR-002 / SC-warmup BR-010).
public struct ProgressionPairSettings: Equatable {
    public var scheme: Scheme
    public var warmupEnabled: Bool

    public init(scheme: Scheme = .none, warmupEnabled: Bool = false) {
        self.scheme = scheme
        self.warmupEnabled = warmupEnabled
    }
}

// MARK: - Prepared materialization (phase 1 → phase 2 handoff)

/// What `prepareMaterialization` computed and `finishMaterialization` persists.
/// Two phases because the engine's deload path needs the NEW session's id to
/// key its re-entry (BR-014), which only exists after Materialize.startSession.
public struct PreparedMaterialization {
    /// The session's future work rows — blueprint rows with the engine's
    /// suggestion stamped over plannedX (BR-001: rows only ever get their
    /// materialized plannedX stamped at session start).
    public var inputs: [Materialize.PlannedSetInput] = []
    /// Records the engine mutated during suggest (deload consumption), to be
    /// persisted once the session id exists.
    var recordUpdates: [(exerciseId: String, record: ProgressionRecord, deloadConsumed: Bool)] = []
    var routineId: String = ""
}

// MARK: - ProgressionModel

@Observable
public final class ProgressionModel {

    // MARK: Observable surface (views render ONLY this)

    /// Stall banners for the attached session, keyed by exerciseId. BR-013:
    /// fires when stallCount == nextBannerAt — derived at materialization and
    /// re-derived on cold attach (#9 r4: recomputed from rows, never carried).
    public private(set) var activeBanners: [String: StallBanner] = [:]

    /// Last write-path error, surfaced inline (copy-driven states only).
    public private(set) var errorMessage: String?

    // MARK: Transient dismissal state (session logic, never persisted)

    /// Dismissing chooses nothing — the banner re-appears next session. These
    /// sets are the ONLY in-memory carry; they never survive a process kill,
    /// matching the rest-cycle precedent (INV-T2).
    private var dismissedActiveExercises: Set<String> = []
    private var dismissedPreviewPairs: Set<String> = []

    // MARK: Session context

    private var activeSessionId: String?
    private var activeRoutineId: String?

    // MARK: Engines & seams (driven, never reimplemented)

    private let dbQueue: DatabaseQueue
    private let progressionDAO: ProgressionDAO
    private let warmupDAO: WarmupDAO
    private let exerciseDAO: ExerciseDAO
    private let routineDAO: RoutineDAO
    private let settingsDAO: SettingsDAO

    /// SC-warmup §6 reference inventory: kg plates [25,20,15,10,5,2.5,1.25],
    /// bar 20. Storage is canonical kg (SC-settings INV-ST2), so the ramp is
    /// always derived in kg regardless of the display unit.
    private let warmupBarWeight: Double = 20.0
    private var warmupPlateInventory: [Double] { WarmupRamp.defaultPlateInventoryKg }

    public init(
        dbQueue: DatabaseQueue,
        progressionDAO: ProgressionDAO,
        warmupDAO: WarmupDAO,
        exerciseDAO: ExerciseDAO,
        routineDAO: RoutineDAO,
        settingsDAO: SettingsDAO
    ) {
        self.dbQueue = dbQueue
        self.progressionDAO = progressionDAO
        self.warmupDAO = warmupDAO
        self.exerciseDAO = exerciseDAO
        self.routineDAO = routineDAO
        self.settingsDAO = settingsDAO
    }

    // MARK: - Materialization seam (WorkoutSessionModel.start drives this)

    /// Phase 1 — BEFORE `Materialize.startSession`: resolve each pair's
    /// reference history (BR-004), run the engine's `suggest`, and stamp the
    /// suggestion over the inputs that become the session's work rows. The
    /// pair's FIRST session keeps blueprint values verbatim (BR-003) — the
    /// engine's own nil-reference path, passed through untouched.
    public func prepareMaterialization(routineId: String, plannedSets: [PlannedSet]) throws -> PreparedMaterialization {
        var prepared = PreparedMaterialization(routineId: routineId)

        // A fresh materialization re-fires any pending preview banner decision.
        dismissedPreviewPairs = dismissedPreviewPairs.filter { !$0.hasPrefix(routineId + "/") }

        // Group the blueprint rows by exercise, first-appearance order.
        var order: [String] = []
        var rowsByExercise: [String: [PlannedSet]] = [:]
        for set in plannedSets {
            if rowsByExercise[set.exerciseId] == nil { order.append(set.exerciseId) }
            rowsByExercise[set.exerciseId, default: []].append(set)
        }

        for exerciseId in order {
            let rows = rowsByExercise[exerciseId] ?? []
            let schemeRow = try progressionDAO.scheme(for: routineId, exerciseId: exerciseId)
            let record = Self.record(from: schemeRow)
            let metric = exerciseMetric(exerciseId)
            let category = try progressionDAO.exerciseCategory(ofExercise: exerciseId)
            let reference = try resolveReference(routineId: routineId, exerciseId: exerciseId)

            let firstWorkRow = rows.first { ($0.setClass ?? .work) == .work } ?? rows.first
            let (suggestion, updated) = ProgressionEngine.suggest(
                record: record,
                reference: reference,
                metric: metric,
                category: category,
                blueprintWeight: firstWorkRow?.plannedWeight,
                blueprintReps: firstWorkRow?.plannedReps,
                blueprintDurationSec: firstWorkRow?.plannedDuration
            )
            let deloadConsumed = record.deloadPending && !updated.deloadPending

            for row in rows {
                let isWork = (row.setClass ?? .work) == .work
                var weight = row.plannedWeight
                var reps = row.plannedReps
                var duration = row.plannedDuration
                if isWork, reference != nil {
                    // Session 2+ of the pair: the engine's suggestion IS the
                    // plan (BR-018: silent plannedX text, no chips). Non-nil
                    // suggestion fields stamp; nil fields keep the blueprint
                    // value (the engine only writes the dimensions it owns).
                    switch metric {
                    case .reps:
                        if let w = suggestion.weight { weight = w }
                        if let r = suggestion.reps { reps = r }
                    case .duration:
                        if let d = suggestion.durationSec { duration = d }
                        if let w = suggestion.weight { weight = w }
                    }
                }
                prepared.inputs.append(Materialize.PlannedSetInput(
                    exerciseId: row.exerciseId,
                    plannedWeight: weight,
                    plannedReps: reps,
                    plannedDuration: duration,
                    setClass: row.setClass.flatMap { MooreWorkout.SetClass(rawValue: $0.rawValue) }
                ))
            }

            if updated != record {
                prepared.recordUpdates.append((exerciseId: exerciseId, record: updated, deloadConsumed: deloadConsumed))
            }
        }
        return prepared
    }

    /// Phase 2 — AFTER `Materialize.startSession` returned the session id:
    /// persist the engine's record mutations (stamping this session's id into
    /// `lastDeloadSessionId` where a deload suggestion was consumed — BR-014's
    /// re-entry key), then run the warm-up write pass post-stamp (SC-warmup
    /// BR-001/BR-008: W reads the materialized work rows; its standalone
    /// invocation is expressly lawful per MooreWarmup/Materialize.swift).
    public func finishMaterialization(sessionId: String, prepared: PreparedMaterialization) {
        do {
            for update in prepared.recordUpdates {
                var record = update.record
                if update.deloadConsumed { record.lastDeloadSessionId = sessionId }
                try saveRecord(record, routineId: prepared.routineId, exerciseId: update.exerciseId)
            }
            try dbQueue.write { db in
                // SC-warmup BR-002's reps-metric gate is enforced by this app
                // layer: the editor hides the toggle for duration exercises AND
                // editorDidSavePair refuses to persist warmupEnabled=1 for them,
                // so by the time this pass reads the column the gate already
                // holds (WarmupMaterialize reads the exercise table's metric
                // dimension by design, keeping MooreWarmup dependency-free).
                try WarmupMaterialize.apply(
                    db: db,
                    sessionId: sessionId,
                    routineId: prepared.routineId,
                    barWeight: self.warmupBarWeight,
                    plateInventory: self.warmupPlateInventory
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Cold-render / resume adoption (#9 r4): re-derive the attached session's
    /// banner surface from the persisted scheme rows. Ad-hoc sessions (nil
    /// routineId) carry no pairs and never banner.
    public func adoptSession(sessionId: String, routineId: String?) {
        activeSessionId = sessionId
        activeRoutineId = routineId
        dismissedActiveExercises = []
        guard let routineId else {
            activeBanners = [:]
            return
        }
        var banners: [String: StallBanner] = [:]
        if let context = try? sessionExerciseContext(sessionId: sessionId) {
            for entry in context {
                guard let row = try? progressionDAO.scheme(for: routineId, exerciseId: entry.exerciseId) else { continue }
                let record = Self.record(from: row)
                if let banner = bannerIfFiring(
                    record: record, routineId: routineId, exerciseId: entry.exerciseId,
                    exerciseName: exerciseName(entry.exerciseId), weightExists: entry.hasWorkWeight
                ) {
                    banners[entry.exerciseId] = banner
                }
            }
        }
        activeBanners = banners
    }

    // MARK: - Stall lifecycle (BR-012..BR-017)

    /// Fired exactly once per finished session (WorkoutSessionModel.finish).
    /// Evaluates every pair the session performed, work-class rows only
    /// (SC-warmup BR-011: warm-up rows can neither trip nor reset a chain).
    /// The banner itself does NOT surface here — BR-013 fires it per
    /// MATERIALIZATION; this only advances the durable counters.
    public func onSessionFinished(sessionId: String) {
        do {
            let routineId = try dbQueue.read { db in
                try String.fetchOne(db, sql: """
                    SELECT routineId FROM workout_session WHERE id = ?
                    """, arguments: [sessionId])
            }
            guard let routineId else { return }   // ad-hoc session: no pairs
            let context = try sessionExerciseContext(sessionId: sessionId)
            for entry in context {
                let currentSets = try progressionDAO.loadWorkSets(sessionId: sessionId, exerciseId: entry.exerciseId)
                let performed = currentSets.filter { $0.status != .dropped }
                guard !performed.isEmpty else { continue }   // BR-012: not performed → no touch

                let schemeRow = try progressionDAO.scheme(for: routineId, exerciseId: entry.exerciseId)
                let record = Self.record(from: schemeRow)
                let previousWeight = try previousPerformedWeight(
                    routineId: routineId, exerciseId: entry.exerciseId, excludingSessionId: sessionId
                )
                let (_, _, updated) = ProgressionEngine.onSessionFinished(
                    record: record,
                    currentSessionSets: currentSets,
                    previousWorkingWeight: previousWeight,
                    metric: exerciseMetric(entry.exerciseId),
                    exerciseName: exerciseName(entry.exerciseId)
                )
                if updated != record {
                    try saveRecord(updated, routineId: routineId, exerciseId: entry.exerciseId)
                }
                // A changed stall state re-surfaces any dismissed preview banner.
                dismissedPreviewPairs.remove(routineId + "/" + entry.exerciseId)
            }
            // The finished session's surface is terminal — drop its banners.
            activeBanners = [:]
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// The attached-session banner for one exercise group (nil ⇔ none/dismissed).
    public func activeBanner(exerciseId: String) -> StallBanner? {
        guard !dismissedActiveExercises.contains(exerciseId) else { return nil }
        return activeBanners[exerciseId]
    }

    /// Dismissal chooses nothing (ticket AC: re-appears next session). The
    /// banner lives on for this session's render only — never persisted.
    public func dismissActiveBanner(exerciseId: String) {
        dismissedActiveExercises.insert(exerciseId)
    }

    /// Routine-preview banner (routine editor): same BR-013 firing condition,
    /// live-read from the persisted scheme row.
    public func previewBanner(routineId: String, exerciseId: String) -> StallBanner? {
        guard !dismissedPreviewPairs.contains(routineId + "/" + exerciseId) else { return nil }
        guard let row = try? progressionDAO.scheme(for: routineId, exerciseId: exerciseId) else { return nil }
        let record = Self.record(from: row)
        let context = stallChoiceContext(routineId: routineId, exerciseId: exerciseId)
        return bannerIfFiring(
            record: record, routineId: routineId, exerciseId: exerciseId,
            exerciseName: exerciseName(exerciseId), weightExists: context.weight != nil
        )
    }

    public func dismissPreviewBanner(routineId: String, exerciseId: String) {
        dismissedPreviewPairs.insert(routineId + "/" + exerciseId)
    }

    /// Tap-to-apply stall choice (BR-014/BR-015/BR-016). Deload snapshots the
    /// CURRENT working values and applies at the NEXT materialization for
    /// exactly one session — never automatically, re-entry at the stalled
    /// weight afterwards. Hold re-asks at stallCount+2; Ignore mutes forever.
    public func applyStallChoice(_ action: StallAction, routineId: String, exerciseId: String) {
        do {
            let schemeRow = try progressionDAO.scheme(for: routineId, exerciseId: exerciseId)
            var record = Self.record(from: schemeRow)
            let context = stallChoiceContext(routineId: routineId, exerciseId: exerciseId)
            record = ProgressionEngine.applyStallChoice(
                action,
                record: record,
                currentWeight: context.weight,
                currentReps: context.reps,
                currentDurationSec: context.durationSec
            )
            try saveRecord(record, routineId: routineId, exerciseId: exerciseId)
            activeBanners[exerciseId] = nil
            dismissedPreviewPairs.remove(routineId + "/" + exerciseId)
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// BR-018: a bottom-sheet edit overrides the suggestion surface and
    /// silently resets the pair's chain. Ad-hoc sessions carry no pair.
    public func resetChainForPair(routineId: String?, exerciseId: String) {
        guard let routineId else { return }
        do {
            let row = try progressionDAO.scheme(for: routineId, exerciseId: exerciseId)
            let reset = ProgressionEngine.resetChainOnEdit(record: Self.record(from: row))
            try saveRecord(reset, routineId: routineId, exerciseId: exerciseId)
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Routine-editor surfaces (scheme + warmup + Next:)

    /// Current persisted pair settings. warmupEnabled reads through WarmupDAO
    /// (never auto-creates — BR-010); the scheme through ProgressionDAO.
    public func pairSettings(routineId: String, exerciseId: String) -> ProgressionPairSettings {
        let scheme = (try? progressionDAO.scheme(for: routineId, exerciseId: exerciseId))
            .flatMap { Scheme(rawValue: $0.scheme) } ?? .none
        let warmup = (try? warmupDAO.warmupEnabled(routineId: routineId, exerciseId: exerciseId)) ?? false
        return ProgressionPairSettings(scheme: scheme, warmupEnabled: warmup)
    }

    /// Routine-editor save hook (BR-002/BR-017): persist the pair's scheme +
    /// warmup toggle AFTER the routine write succeeded. A scheme change or a
    /// blueprint-weight edit (`chainReset`) resets the stall chain. Adopting
    /// hold-duration captures the baseline that anchors the +60s cap (BR-008).
    /// The warm-up gate is reps-metric (SC-warmup BR-002); duration-metric
    /// pairs can NEVER persist warmupEnabled=1 — the app is the only writer of
    /// this column, so enforcing it here makes the DB invariant absolute, not
    /// just a UI affordance.
    public func editorDidSavePair(
        routineId: String,
        exerciseId: String,
        scheme: Scheme,
        warmupEnabled: Bool,
        chainReset: Bool,
        blueprintDurationSec: Int?
    ) {
        do {
            let row = try progressionDAO.scheme(for: routineId, exerciseId: exerciseId)
            var record = Self.record(from: row)
            let schemeChanged = record.scheme != scheme
            if scheme == .holdDuration, record.baselineDurationSec == nil {
                record.baselineDurationSec = blueprintDurationSec ?? 60
            }
            record.scheme = scheme
            if chainReset || schemeChanged {
                record = ProgressionEngine.resetChainOnEdit(record: record)
            }
            let gatedWarmup = warmupEnabled && isRepsMetric(exerciseId)
            try saveRecord(record, warmupEnabled: gatedWarmup, routineId: routineId, exerciseId: exerciseId)
            dismissedPreviewPairs.remove(routineId + "/" + exerciseId)
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// BR-018 routine preview: the one-line "Next:" text — what the next
    /// session will materialize for this pair (progression.nextLine key).
    /// Render-only: the engine's returned record mutation (deload consumption)
    /// is deliberately DISCARDED — suggestions are materialization-time state
    /// writes, never preview-time (BR-020).
    public func nextLineText(routineId: String, exerciseId: String) -> String? {
        guard let sets = try? routineDAO.fetchSets(routineId: routineId) else { return nil }
        let pairSets = sets.filter { $0.exerciseId == exerciseId && ($0.setClass ?? .work) == .work }
        guard let first = pairSets.first else { return nil }
        guard let record = currentRecord(routineId: routineId, exerciseId: exerciseId) else { return nil }

        let metric = exerciseMetric(exerciseId)
        let reference = (try? resolveReference(routineId: routineId, exerciseId: exerciseId)) ?? nil
        let category = (try? progressionDAO.exerciseCategory(ofExercise: exerciseId)) ?? nil
        let (suggestion, _) = ProgressionEngine.suggest(
            record: record,
            reference: reference,
            metric: metric,
            category: category,
            blueprintWeight: first.plannedWeight,
            blueprintReps: first.plannedReps,
            blueprintDurationSec: first.plannedDuration
        )

        // Mirror the materialization stamp so the preview shows exactly what
        // the session rows will carry.
        var weight = first.plannedWeight
        var reps = first.plannedReps
        var duration = first.plannedDuration
        if reference != nil {
            switch metric {
            case .reps:
                if let w = suggestion.weight { weight = w }
                if let r = suggestion.reps { reps = r }
            case .duration:
                if let d = suggestion.durationSec { duration = d }
                if let w = suggestion.weight { weight = w }
            }
        }

        let name = exerciseName(exerciseId)
        switch metric {
        case .reps:
            guard let weight, let reps else { return nil }
            return UICopy.progressionNextLine(name: name, value: "\(displayWeight(weight))×\(reps)")
        case .duration:
            guard let duration else { return nil }
            return UICopy.progressionNextLine(name: name, value: UICopy.restOverlayRemaining(seconds: duration))
        }
    }

    // MARK: - Display helpers

    /// Canonical kg → display-unit render (SC-settings BR-002 frozen shape).
    public func displayWeight(_ kg: Double) -> String {
        let unit = (try? settingsDAO.fetchSettings().weightUnit) ?? .kg
        return SettingsEngine.displayString(rawKg: kg, unit: unit)
    }

    public func exerciseName(_ exerciseId: String) -> String {
        (try? exerciseDAO.getById(exerciseId))?.name ?? exerciseId
    }

    public func exerciseMetric(_ exerciseId: String) -> ExerciseMetric {
        let exercise = try? exerciseDAO.getById(exerciseId)
        return exercise?.defaultMetric == .duration ? .duration : .reps
    }

    /// True when the exercise progresses by reps — the SC-warmup BR-002 gate
    /// dimension the editor toggle honors (duration-metric exercises never
    /// ramp; their toggle stays hidden).
    public func isRepsMetric(_ exerciseId: String) -> Bool {
        exerciseMetric(exerciseId) == .reps
    }

    // MARK: - Internals

    /// BR-013 firing condition, shared by the materialization and preview
    /// surfaces: the banner exists exactly while stallCount == nextBannerAt
    /// (unmuted). Copy shape per SC-progression §5.
    private func bannerIfFiring(
        record: ProgressionRecord,
        routineId: String,
        exerciseId: String,
        exerciseName: String,
        weightExists: Bool
    ) -> StallBanner? {
        guard !record.stallMuted, record.stallCount > 0, record.stallCount == record.nextBannerAt else {
            return nil
        }
        return StallBanner(
            routineId: routineId,
            exerciseId: exerciseId,
            exerciseName: exerciseName,
            copy: UICopy.progressionBannerStall(name: exerciseName, n: record.stallCount),
            stallCount: record.stallCount,
            deloadAvailable: weightExists
        )
    }

    /// BR-004 reference resolution over the DAO's ≤5-session window: the
    /// newest session with ≥1 non-dropped WORK-class set; nil ⇔ session 1 of
    /// the pair (BR-003 blueprint-verbatim path).
    private func resolveReference(routineId: String, exerciseId: String) throws -> [MooreProgression.ReferenceSessionSet]? {
        let history = try progressionDAO.referenceHistory(routineId: routineId, exerciseId: exerciseId)
        for entry in history {
            let sets = try progressionDAO.loadWorkSets(sessionId: entry.sessionId, exerciseId: exerciseId)
            if sets.contains(where: { $0.status != .dropped }) {
                return sets
            }
        }
        return nil
    }

    /// BR-012(b) input: the working weight of the newest PRIOR session that
    /// performed this exercise (work-class, non-dropped); nil when there was
    /// none. Resolved within the same BR-004 window the engine owns.
    private func previousPerformedWeight(routineId: String, exerciseId: String, excludingSessionId: String) throws -> Double? {
        let history = try progressionDAO.referenceHistory(routineId: routineId, exerciseId: exerciseId)
        for entry in history where entry.sessionId != excludingSessionId {
            let sets = try progressionDAO.loadWorkSets(sessionId: entry.sessionId, exerciseId: exerciseId)
            let performed = sets.filter { $0.status != .dropped }
            guard !performed.isEmpty else { continue }
            return performed.max(by: { $0.setOrdinal < $1.setOrdinal })?.actualWeight
        }
        return nil
    }

    /// BR-014 snapshot inputs — "the current working weight the session
    /// materialized at". The attached session's stamped rows when the pair
    /// belongs to it; otherwise the resolved reference (preview surfaces),
    /// falling back to the blueprint.
    private func stallChoiceContext(routineId: String, exerciseId: String) -> (weight: Double?, reps: Int?, durationSec: Int?) {
        if activeRoutineId == routineId, let sessionId = activeSessionId,
           let rows = try? sessionWorkRows(sessionId: sessionId, exerciseId: exerciseId),
           !rows.isEmpty {
            let weight = rows.compactMap(\.plannedWeight).max()
            return (weight, rows.first?.plannedReps, rows.first?.plannedDuration)
        }
        if let reference = try? resolveReference(routineId: routineId, exerciseId: exerciseId),
           let last = reference.filter({ $0.status != .dropped }).max(by: { $0.setOrdinal < $1.setOrdinal }) {
            return (last.actualWeight, last.plannedReps, last.plannedDuration)
        }
        if let sets = try? routineDAO.fetchSets(routineId: routineId) {
            let pairSets = sets.filter { $0.exerciseId == exerciseId && ($0.setClass ?? .work) == .work }
            if let first = pairSets.first {
                return (first.plannedWeight, first.plannedReps, first.plannedDuration)
            }
        }
        return (nil, nil, nil)
    }

    private func currentRecord(routineId: String, exerciseId: String) -> ProgressionRecord? {
        guard let row = try? progressionDAO.scheme(for: routineId, exerciseId: exerciseId) else { return nil }
        return Self.record(from: row)
    }

    // MARK: Session-shape reads (progression-scoped, work-class aware)

    private struct SessionExerciseEntry {
        var exerciseId: String
        var hasWorkWeight: Bool
    }

    /// Distinct exercises of a session in render order, with the "does this
    /// pair have a loadable working weight" flag the Deload CTA gates on.
    private func sessionExerciseContext(sessionId: String) throws -> [SessionExerciseEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT exerciseId,
                       MAX(CASE WHEN (setClass IS NULL OR setClass = 'work')
                                  AND plannedWeight IS NOT NULL THEN 1 ELSE 0 END) AS hasWorkWeight
                FROM completed_set
                WHERE sessionId = ? AND deletedAt IS NULL
                GROUP BY exerciseId
                ORDER BY MIN(sortOrder) ASC
                """, arguments: [sessionId])
            return rows.map { row in
                SessionExerciseEntry(exerciseId: row["exerciseId"], hasWorkWeight: row["hasWorkWeight"] == 1)
            }
        }
    }

    private struct PlannedValues {
        var plannedWeight: Double?
        var plannedReps: Int?
        var plannedDuration: Int?
    }

    /// The pair's work-class rows of the attached session (post-stamp plannedX).
    private func sessionWorkRows(sessionId: String, exerciseId: String) throws -> [PlannedValues] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT plannedWeight, plannedReps, plannedDuration
                FROM completed_set
                WHERE sessionId = ? AND exerciseId = ?
                  AND (setClass IS NULL OR setClass = 'work')
                  AND deletedAt IS NULL
                ORDER BY sortOrder ASC
                """, arguments: [sessionId, exerciseId])
            .map { row in
                PlannedValues(
                    plannedWeight: row["plannedWeight"],
                    plannedReps: row["plannedReps"],
                    plannedDuration: row["plannedDuration"]
                )
            }
        }
    }

    // MARK: Record ↔ row mapping (the DAO seam translation)

    private static func record(from row: ProgressionSchemeRow) -> ProgressionRecord {
        ProgressionRecord(
            id: row.id,
            routineId: row.routineId,
            exerciseId: row.exerciseId,
            scheme: Scheme(rawValue: row.scheme) ?? .none,
            stallCount: row.stallCount,
            stallMuted: row.stallMuted == 1,
            nextBannerAt: row.nextBannerAt,
            deloadPending: row.deloadPending == 1,
            lastDeloadSessionId: row.lastDeloadSessionId,
            stalledWeight: row.stalledWeight,
            stalledReps: row.stalledReps,
            stalledDurationSec: row.stalledDurationSec,
            baselineDurationSec: row.baselineDurationSec,
            updatedAt: ISO8601DateFormatter().date(from: row.updatedAt) ?? Date()
        )
    }

    /// Persist one record. `warmupEnabled` nil leaves the column untouched
    /// (progression writes never side-effect the warm-up gate).
    private func saveRecord(
        _ record: ProgressionRecord,
        warmupEnabled: Bool? = nil,
        routineId: String,
        exerciseId: String
    ) throws {
        var row = try progressionDAO.scheme(for: routineId, exerciseId: exerciseId)
        row.scheme = record.scheme.rawValue
        row.stallCount = record.stallCount
        row.stallMuted = record.stallMuted ? 1 : 0
        row.nextBannerAt = record.nextBannerAt
        row.deloadPending = record.deloadPending ? 1 : 0
        row.lastDeloadSessionId = record.lastDeloadSessionId
        row.stalledWeight = record.stalledWeight
        row.stalledReps = record.stalledReps
        row.stalledDurationSec = record.stalledDurationSec
        row.baselineDurationSec = record.baselineDurationSec
        if let warmupEnabled { row.warmupEnabled = warmupEnabled ? 1 : 0 }
        try progressionDAO.save(row)
    }
}
