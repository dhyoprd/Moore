// contractId: SC-prs @1.0.0
// §3a model + seam-1 value types. Canonical post-0008 shape. Additive-only.
// Mechanical Kotlin port of Sources/MooreRecords/PersonalRecord.swift.
package com.moore.records

import com.moore.foundation.SetClass
import com.moore.foundation.SetStatus

enum class PRKind(val raw: String) {
    MAX_1RM("max_1rm"),
    MAX_VOLUME("max_volume"),
    MAX_REPS("max_reps"),
    MAX_DURATION("max_duration");

    /// BR-005 precedence (0 = highest). Explicit so enum declaration order
    /// is never load-bearing.
    val precedenceRank: Int
        get() = when (this) {
            MAX_1RM -> 0
            MAX_VOLUME -> 1
            MAX_REPS -> 2
            MAX_DURATION -> 3
        }

    companion object {
        /// Declaration order = allCases (SC-prs closed vocabulary).
        val allCases: List<PRKind> get() = entries
        fun fromRaw(raw: String): PRKind = entries.first { it.raw == raw }
    }
}

data class PersonalRecord(
    var id: String,
    var exerciseId: String,
    var sessionId: String,    // session where achieved; '' sentinel only via legacy 0001→0008 backfill
    var setId: String?,
    var kind: PRKind,
    var value: Double,        // unit per kind (§3b); unrounded
    var achievedAt: String,   // = holding set's completedAt
    var createdAt: String,
    var updatedAt: String,
    var deletedAt: String? = null,
)

/// Exercise metric at the seam: reps-metric (weight×reps) vs duration-metric.
enum class SeamMetric(val raw: String) {
    REPS("reps"), DURATION("duration");

    companion object {
        fun fromRaw(raw: String?): SeamMetric? = entries.firstOrNull { it.raw == raw }
    }
}

/// Seam-1 input — minimal CompletedSet view consumed by PREngine. Carries
/// `exerciseDefaultMetric` so max_duration gating needs no DB round-trip.
data class ReferenceSessionSet(
    var id: String,
    var sessionId: String,
    var exerciseId: String,
    var status: SetStatus,
    var setClass: SetClass? = null,      // null coalesces to work (INV-6)
    var actualWeight: Double? = null,
    var actualReps: Int? = null,
    var actualDuration: Int? = null,
    var completedAt: String? = null,
    var exerciseDefaultMetric: SeamMetric? = null,
)

/// Cue descriptor for `cue.pr.achieved`. Callers dispatch; the engine only
/// describes. Haptic class is #10's `celebration`; toast copy is §6-keyed.
data class PRFiredCue(
    var cueId: String,
    var hapticClass: String,
    var headlineKind: PRKind,
    var value: Double,
    var exerciseId: String,
) {
    constructor(headlineKind: PRKind, value: Double, exerciseId: String) :
        this("cue.pr.achieved", "celebration", headlineKind, value, exerciseId)
}

/// What `processNewSet`/`writeFromSet` return. Live path only ever contains
/// beaten kinds (BR-002: no baseline row ⇒ nothing written, nothing fired) —
/// `written == beaten`. Exactly one cue descriptor comes back, headline per
/// BR-005 precedence, when at least one kind beat its baseline.
data class PRWrite(
    var written: List<PRKind>,
    var beaten: List<PRKind>,
    var values: Map<PRKind, Double>,
    var fired: PRFiredCue?,
)
