// contractId: SC-prs @1.0.0
// §4–§5 two-path engine, per binding ticket ruling:
//
//   processNewSet  — LIVE path, fired on set completion. Writes/cues ONLY when
//                    a baseline row for (exerciseId, kind) already exists AND the
//                    new value strictly exceeds it. Never seeds. (BR-002)
//   rederive       — MAINTENANCE path, fired on import / edit / delete. Seeds
//                    baseline rows where none exist; rewrites holders whose
//                    bookmark moved; tombstones kinds that no longer qualify.
//                    Never cues. (BR-007/BR-008/BR-009)
//
// Closed-form, pure, byte-identical across platforms (§9).
// Mechanical Kotlin port of Sources/MooreRecords/PREngine.swift.
package com.moore.records

import com.moore.foundation.SetClass
import com.moore.foundation.SetStatus

data class RederivedBookmark(
    val value: Double,
    val setId: String?,
    val sessionId: String?,
    val achievedAt: String?,
)

object PREngine {

    /// Epley 1RM: weight × (1 + reps/30). Stored unrounded (BR-003).
    fun epley1RM(weight: Double, reps: Int): Double = weight * (1.0 + reps.toDouble() / 30.0)

    /// BR-001 candidate gate: `status = completed` AND `coalesce(setClass,'work') = 'work'`.
    /// Failed/dropped never qualify; warmup rows are invisible.
    fun isEligibleWorkSet(s: ReferenceSessionSet): Boolean {
        if (s.status != SetStatus.COMPLETED) return false
        return (s.setClass ?: SetClass.WORK) == SetClass.WORK
    }

    /// BR-004 per-kind computed value, null when BR-004's gate excludes the set.
    fun valueOf(kind: PRKind, s: ReferenceSessionSet): Double? {
        if (!isEligibleWorkSet(s)) return null
        return when (kind) {
            PRKind.MAX_1RM -> {
                val w = s.actualWeight
                val r = s.actualReps
                if (w != null && w > 0 && r != null && r > 0) epley1RM(w, r) else null
            }
            PRKind.MAX_VOLUME -> {
                val w = s.actualWeight
                val r = s.actualReps
                if (w != null && w > 0 && r != null && r > 0) w * r.toDouble() else null
            }
            PRKind.MAX_REPS -> {
                val r = s.actualReps
                if (r != null && r > 0) r.toDouble() else null
            }
            PRKind.MAX_DURATION -> {
                if (s.exerciseDefaultMetric != SeamMetric.DURATION) null
                else {
                    val d = s.actualDuration
                    if (d != null && d > 0) d.toDouble() else null
                }
            }
        }
    }

    /// LIVE path (BR-002/BR-003/BR-005/BR-006). First-ever set for an exercise
    /// NEVER fires: with no pre-existing baseline row there is nothing to beat,
    /// and this function writes nothing. Baselines are created exclusively by
    /// `rederive` (import / edit / delete) or by prior `processNewSet` writes.
    ///
    /// When the candidate beats multiple kinds, every beaten kind's row upserts
    /// (INV-PR2) but exactly one cue descriptor comes back — headline per BR-005
    /// precedence. Strict exceed only; equality writes nothing (BR-003).
    fun processNewSet(
        set: ReferenceSessionSet,
        baselines: Map<PRKind, PersonalRecord>,
    ): PRWrite? {
        if (!isEligibleWorkSet(set)) return null

        val beaten = mutableListOf<PRKind>()
        val values = mutableMapOf<PRKind, Double>()
        for (kind in PRKind.allCases) {
            val baseline = baselines[kind] ?: continue       // no row → nothing to beat (BR-002)
            val v = valueOf(kind, set) ?: continue           // BR-001/BR-004 gate
            if (v <= baseline.value) continue                // BR-003 strict exceed
            beaten.add(kind)
            values[kind] = v
        }
        if (beaten.isEmpty()) return null

        beaten.sortBy { it.precedenceRank }
        val fired = PRFiredCue(
            headlineKind = beaten[0],
            value = values[beaten[0]] ?: 0.0,
            exerciseId = set.exerciseId,
        )
        return PRWrite(written = beaten.toList(), beaten = beaten.toList(), values = values, fired = fired)
    }

    /// MAINTENANCE path (BR-007/BR-008/BR-009). Recompute the per-kind bookmark
    /// over the exercise's full live history (INV-PR4). Holder per kind = max
    /// value; ties keep earliest completedAt. Silent by construction: returns
    /// bookmark descriptors only, never a cue (BR-009).
    fun rederive(exerciseHistory: List<ReferenceSessionSet>): Map<PRKind, RederivedBookmark> {
        val work = exerciseHistory.filter { isEligibleWorkSet(it) }
        if (work.isEmpty()) return emptyMap()

        val out = mutableMapOf<PRKind, RederivedBookmark>()
        for (kind in PRKind.allCases) {
            var holder: ReferenceSessionSet? = null
            var best: Double? = null
            for (s in work) {
                val v = valueOf(kind, s) ?: continue
                val b = best
                if (b == null || v > b || (v == b && earlierWins(s, holder))) {
                    best = v
                    holder = s
                }
            }
            val h = holder
            val bv = best
            if (h != null && bv != null) {
                out[kind] = RederivedBookmark(bv, h.id, h.sessionId, h.completedAt)
            }
        }
        return out
    }

    /// completedAt ordering with id tiebreak (ISO-8601 UTC text).
    private fun earlierWins(a: ReferenceSessionSet, b: ReferenceSessionSet?): Boolean {
        if (b == null) return true
        val at = a.completedAt ?: ""
        val bt = b.completedAt ?: ""
        if (at != bt) return at < bt
        return a.id < b.id
    }
}
