// SC-progression@1.0.0 — pure, rules-based progression engine (no platform imports).
// Mechanical Kotlin port of Sources/MooreProgression/ProgressionEngine.swift;
// mirrors the contract's BR-001..BR-020 literally; every function closed-form.
package com.moore.progression

import com.moore.foundation.SetStatus
import com.moore.foundation.roundAwayFromZero
import kotlin.math.max

// MARK: - Types

enum class Scheme(val raw: String) {
    NONE("none"), LINEAR("linear"), DOUBLE("double"), HOLD_DURATION("hold-duration");

    companion object {
        fun fromRaw(raw: String): Scheme = entries.first { it.raw == raw }
    }
}

enum class StallAction(val raw: String) {
    DELOAD("deload"), HOLD("hold"), IGNORE("ignore");

    companion object {
        fun fromRaw(raw: String): StallAction = entries.first { it.raw == raw }
    }
}

data class Suggestion(
    var weight: Double? = null,
    var reps: Int? = null,
    var durationSec: Int? = null,
    var touched: List<String> = emptyList(),   // debug: which suggestion path wrote this
)

data class StallState(
    var shouldBanner: Boolean,
    var bannerCopy: String? = null,
)

data class ProgressionRecord(
    var id: String,
    var routineId: String,
    var exerciseId: String,
    var scheme: Scheme = Scheme.NONE,
    var stallCount: Int = 0,
    var stallMuted: Boolean = false,
    var nextBannerAt: Int = 3,
    var deloadPending: Boolean = false,
    var lastDeloadSessionId: String? = null,
    var stalledWeight: Double? = null,
    var stalledReps: Int? = null,
    var stalledDurationSec: Int? = null,
    var baselineDurationSec: Int? = null,
    var updatedAt: String = "",
)

// MARK: - Aggregates over a reference session

data class ReferenceSessionSet(
    var sessionId: String,
    var routineId: String? = null,
    var status: SetStatus,                     // completed | failed | dropped
    var exerciseId: String,
    var setOrdinal: Int,
    var plannedWeight: Double? = null,
    var plannedReps: Int? = null,
    var plannedDuration: Int? = null,
    var actualWeight: Double? = null,
    var actualReps: Int? = null,
    var actualDuration: Int? = null,
)

enum class ExerciseMetric { REPS, DURATION }

// MARK: - Engine

data class SuggestResult(val suggestion: Suggestion, val updatedRecord: ProgressionRecord)
data class SessionFinishedResult(
    val shouldBanner: Boolean,
    val bannerCopy: String?,
    val updatedRecord: ProgressionRecord,
)

object ProgressionEngine {

    // inc(E) per BR-009. Categories land on exercise.category (SC-exercises); the
    // upper-biased rule intentionally includes nil/miss cases.
    fun incrementForExerciseCategory(category: String?): Double {
        val cat = category?.lowercase() ?: return 2.5
        val lower = listOf("legs", "quads", "hamstrings", "glutes", "calves")
        return if (lower.any { cat.contains(it) }) 5.0 else 2.5
    }

    // round125: nearest 1.25 kg, half-up (away from zero), floored at 0.
    fun round125(x: Double): Double = max(0.0, roundAwayFromZero(x / 1.25) * 1.25)

    // round25: nearest 2.5 kg, half-up. Used ONLY for deload.
    fun round25(x: Double): Double = roundAwayFromZero(x / 2.5) * 2.5

    // Clean-session predicate per BR-006. reps/duration discriminated by metric.
    fun clean(sets: List<ReferenceSessionSet>, metric: ExerciseMetric): Boolean {
        val performed = sets.filter { it.status != SetStatus.DROPPED }
        if (performed.isEmpty()) return false
        if (performed.any { it.status == SetStatus.FAILED }) return false
        return when (metric) {
            ExerciseMetric.REPS -> performed.all { (it.actualReps ?: 0) >= (it.plannedReps ?: 0) }
            ExerciseMetric.DURATION -> performed.all { (it.actualDuration ?: 0) >= (it.plannedDuration ?: 0) }
        }
    }

    // Failed-set donation: MAX(actualReps/actualDuration) across the session's
    // failed sets for E, per BR-007.
    fun failedMax(sets: List<ReferenceSessionSet>, metric: ExerciseMetric): Int? {
        val fails = sets.filter { it.status == SetStatus.FAILED }
        if (fails.isEmpty()) return null
        return when (metric) {
            ExerciseMetric.REPS -> fails.mapNotNull { it.actualReps }.maxOrNull()
            ExerciseMetric.DURATION -> fails.mapNotNull { it.actualDuration }.maxOrNull()
        }
    }

    // Core suggestion over the LATEST reference the caller resolved (BR-004 windowing
    // happens upstream — this function assumes `reference` is the resolved candidate).
    fun suggest(
        record: ProgressionRecord,
        reference: List<ReferenceSessionSet>?,      // null = session 1 (BR-003)
        metric: ExerciseMetric,
        category: String?,
        blueprintWeight: Double?,
        blueprintReps: Int?,
        blueprintDurationSec: Int?,
    ): SuggestResult {
        val rec = record.copy()

        // Session one or unresolvable reference → blueprint verbatim (BR-003).
        if (reference.isNullOrEmpty()) {
            return SuggestResult(
                Suggestion(blueprintWeight, blueprintReps, blueprintDurationSec, listOf("blueprint-verbatim")),
                record,
            )
        }

        // BR-014 deload path.
        if (rec.deloadPending && rec.stalledWeight != null) {
            rec.deloadPending = false
            rec.lastDeloadSessionId = null   // caller stamps with this session's id
            rec.stallCount = 0
            val w = round25(rec.stalledWeight!! * 0.90)
            return when (metric) {
                ExerciseMetric.REPS -> SuggestResult(
                    Suggestion(w, rec.stalledReps, null, listOf("deload-applied")), rec)
                ExerciseMetric.DURATION -> SuggestResult(
                    Suggestion(w, null, rec.stalledDurationSec, listOf("deload-applied")), rec)
            }
        }

        // BR-014 re-entry: if the reference session IS the last deload session,
        // unconditionally re-enter at the stalled values.
        val lastDeload = rec.lastDeloadSessionId
        val refSessionId = reference.firstOrNull()?.sessionId
        if (lastDeload != null && refSessionId == lastDeload) {
            return when (metric) {
                ExerciseMetric.REPS -> SuggestResult(
                    Suggestion(rec.stalledWeight, rec.stalledReps, null, listOf("deload-reentry")), rec)
                ExerciseMetric.DURATION -> SuggestResult(
                    Suggestion(rec.stalledWeight, null, rec.stalledDurationSec, listOf("deload-reentry")), rec)
            }
        }

        val performed = reference.filter { it.status != SetStatus.DROPPED }
        val last = performed.maxByOrNull { it.setOrdinal }
            ?: return SuggestResult(
                Suggestion(blueprintWeight, blueprintReps, blueprintDurationSec, listOf("blueprint-verbaim-no-performed")),
                record,
            )
        val w = last.actualWeight
        val p: Int? = if (metric == ExerciseMetric.REPS) last.plannedReps else last.plannedDuration
        val c = clean(performed, metric)
        val f = failedMax(performed, metric)

        // Not clean → hold weight; target from best effort (BR-007)
        if (!c) {
            val target: Int? = if (f != null) (if (p != null) minOf(p, f) else f) else p
            return when (metric) {
                ExerciseMetric.REPS -> SuggestResult(
                    Suggestion(w, target, null, listOf("hold-weight-from-fail")), rec)
                ExerciseMetric.DURATION -> SuggestResult(
                    Suggestion(w, null, target, listOf("hold-weight-from-fail")), rec)
            }
        }

        // Clean → scheme math (BR-008)
        val inc = incrementForExerciseCategory(category)
        return when (rec.scheme) {
            Scheme.NONE -> SuggestResult(
                Suggestion(w, last.actualReps, last.actualDuration, listOf("none-verbatim")), rec)
            Scheme.LINEAR -> {
                if (w == null) {
                    // Bodyweight: linear degenerates to none per BR-011
                    SuggestResult(
                        Suggestion(null, last.actualReps, last.actualDuration, listOf("linear-degenerate-none")), rec)
                } else {
                    SuggestResult(
                        Suggestion(round125(w + inc), last.plannedReps, last.plannedDuration, listOf("linear")), rec)
                }
            }
            Scheme.DOUBLE -> {
                val pTarget = last.plannedReps ?: 8
                val reps = last.actualReps ?: pTarget
                if (reps >= 12 && w != null) {
                    SuggestResult(Suggestion(round125(w + inc), 8, null, listOf("double-ceiling")), rec)
                } else {
                    SuggestResult(Suggestion(w, minOf(reps + 1, 12), null, listOf("double-reps")), rec)
                }
            }
            Scheme.HOLD_DURATION -> {
                val baseline = rec.baselineDurationSec ?: (last.plannedDuration ?: 60)
                val cap = baseline + 60
                val next = minOf((last.actualDuration ?: baseline) + 5, cap)
                SuggestResult(Suggestion(null, null, next, listOf("hold-duration")), rec)
            }
        }
    }

    // Stall evaluation on finished session (BR-012..BR-016). Caller passes the current
    // session's performed sets for E and the immediate previous performed session's
    // working weight (null if there was none).
    fun onSessionFinished(
        record: ProgressionRecord,
        currentSessionSets: List<ReferenceSessionSet>,
        previousWorkingWeight: Double?,
        metric: ExerciseMetric,
        exerciseName: String,
    ): SessionFinishedResult {
        val performedNow = currentSessionSets.filter { it.status != SetStatus.DROPPED }
        // not performed → no touch
        if (performedNow.isEmpty()) return SessionFinishedResult(false, null, record)

        val rec = record.copy()
        val currentW = performedNow.maxByOrNull { it.setOrdinal }?.actualWeight

        // Weight change resets chain — even mid-stall.
        if (previousWorkingWeight != null && currentW != null && previousWorkingWeight != currentW) {
            rec.stallCount = 0
            return SessionFinishedResult(false, null, rec)
        }

        if (clean(performedNow, metric)) {
            rec.stallCount = 0
            return SessionFinishedResult(false, null, rec)
        }

        val failedMaxActual = failedMax(performedNow, metric)
        val targetP = if (metric == ExerciseMetric.REPS) performedNow.firstOrNull()?.plannedReps
        else performedNow.firstOrNull()?.plannedDuration
        if (failedMaxActual != null && targetP != null && failedMaxActual < targetP) {
            rec.stallCount += 1
        }
        // else (completed shortfall with no fails) → unchanged per BR-012(d).

        if (!rec.stallMuted && rec.stallCount == rec.nextBannerAt) {
            val copy = "Looks stalled on $exerciseName — ${rec.stallCount} sessions short of target."
            return SessionFinishedResult(true, copy, rec)
        }
        return SessionFinishedResult(false, null, rec)
    }

    // Stall-choice application. Caller passes the CURRENT working weight the session
    // materialized at (for Deload snapshotting).
    fun applyStallChoice(
        action: StallAction,
        record: ProgressionRecord,
        currentWeight: Double?,
        currentReps: Int?,
        currentDurationSec: Int?,
    ): ProgressionRecord {
        val rec = record.copy()
        when (action) {
            StallAction.DELOAD -> {
                rec.deloadPending = true
                rec.stalledWeight = currentWeight
                rec.stalledReps = currentReps
                rec.stalledDurationSec = currentDurationSec
            }
            StallAction.HOLD -> rec.nextBannerAt = rec.stallCount + 2
            StallAction.IGNORE -> rec.stallMuted = true
        }
        return rec
    }

    // Editor touch: resets chain per BR-017.
    fun resetChainOnEdit(record: ProgressionRecord): ProgressionRecord {
        val rec = record.copy()
        rec.stallCount = 0
        rec.stallMuted = false
        rec.nextBannerAt = 3
        rec.deloadPending = false
        rec.stalledWeight = null
        rec.stalledReps = null
        rec.stalledDurationSec = null
        return rec
    }
}
