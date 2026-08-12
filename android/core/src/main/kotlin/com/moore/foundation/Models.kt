// SC-foundation@1.0.0 — §3 Data Schema, typed row models.
// Mechanical Kotlin port of Sources/MooreFoundation/Models.swift (#31 naming map:
// Swift struct ↔ Kotlin data class, identical field names). Timestamps are
// ISO-8601 UTC text exactly as stored by the shared .sql migrations.
package com.moore.foundation

enum class ExerciseType(val raw: String) {
    STRENGTH("strength"), CARDIO("cardio"), CUSTOM("custom");

    companion object {
        fun fromRaw(raw: String): ExerciseType = entries.first { it.raw == raw }
    }
}

/// Warm-up vs work classification (SC-foundation INV-6). Nil reads coalesce to work.
enum class SetClass(val raw: String) {
    WARMUP("warmup"), WORK("work");

    companion object {
        fun fromRaw(raw: String?): SetClass? = entries.firstOrNull { it.raw == raw }
    }
}

/// Lifecycle of one CompletedSet row; mirrors the SQL CHECK on completed_set.status.
enum class SetStatus(val raw: String) {
    PLANNED("planned"), COMPLETED("completed"), FAILED("failed"), DROPPED("dropped");

    /// completed / failed / dropped are terminal (§2a, BR-008's finish check).
    val isTerminal: Boolean get() = this != PLANNED

    companion object {
        fun fromRaw(raw: String): SetStatus = entries.first { it.raw == raw }
    }
}

/// Legacy 0001 personal-record vocabulary (pre-0008 readers).
enum class PRKindLegacy(val raw: String) { WEIGHT("weight"), VOLUME("volume"), REP("rep") }

enum class MetricKind(val raw: String) { BODY_WEIGHT("bodyWeight"), BODY_FAT("bodyFat"), WEIGHT("weight") }
enum class MetricUnit(val raw: String) { KG("kg"), LB("lb"), PCT("pct") }
enum class ProgressionSchemeKind(val raw: String) { LINEAR("linear"), DOUBLE("double"), PERCENTAGE("percentage") }

data class Folder(
    var id: String,
    var name: String,
    var createdAt: String,
    var updatedAt: String,
    var deletedAt: String? = null,
)

data class Exercise(
    var id: String,
    var name: String,
    var exerciseType: ExerciseType,
    var equipmentSlug: String? = null,
    var primaryMuscleId: String? = null,
    var secondaryMuscleIdsJson: String? = null,
    var instructions: String? = null,
    var isCustom: Int,
    var createdAt: String,
    var updatedAt: String,
    var deletedAt: String? = null,
)

data class RoutineRow(
    var id: String,
    var folderId: String? = null,
    var name: String,
    var sortOrder: Int = 0,
    var createdAt: String,
    var updatedAt: String,
    var deletedAt: String? = null,
)

data class PlannedSetRow(
    var id: String,
    var routineId: String,
    var exerciseId: String,
    var sortOrder: Int,
    var plannedWeight: Double? = null,
    var plannedReps: Int? = null,
    var plannedDuration: Int? = null,
    var setClass: SetClass? = null,   // INV-6: NULL from pre-0002 rows; readers coalesce to work
    var createdAt: String,
    var updatedAt: String,
    var deletedAt: String? = null,
)

data class WorkoutSession(
    var id: String,
    var name: String? = null,
    var notes: String? = null,
    var startedAt: String,
    var endedAt: String? = null,
    var importSource: String? = null,
    var importKey: String? = null,
    var createdAt: String,
    var updatedAt: String,
    var deletedAt: String? = null,
)

data class CompletedSet(
    var id: String,
    var sessionId: String,
    var exerciseId: String,
    var sortOrder: Int,
    var plannedWeight: Double? = null,
    var plannedReps: Int? = null,
    var plannedDuration: Int? = null,
    var actualWeight: Double? = null,
    var actualReps: Int? = null,
    var actualDuration: Int? = null,
    var status: SetStatus,
    var setClass: SetClass? = null,   // INV-6
    var completedAt: String? = null,
    var createdAt: String,
    var updatedAt: String,
    var deletedAt: String? = null,
)

data class BodyMetricRow(
    var id: String,
    var kind: MetricKind,
    var value: Double,
    var unit: MetricUnit,
    var recordedAt: String,
    var createdAt: String,
    var updatedAt: String,
    var deletedAt: String? = null,
)

data class ProgressionScheme(
    var id: String,
    var routineId: String,
    var exerciseId: String,
    var scheme: ProgressionSchemeKind,
    var incrementValue: Double? = null,
    var doubleProgressionMinReps: Int? = null,
    var doubleProgressionMaxReps: Int? = null,
    var warmupEnabled: Int,
    var stallCount: Int,
    var stallMuted: Int,
    var lastDeloadSessionId: String? = null,
    var createdAt: String,
    var updatedAt: String,
    var deletedAt: String? = null,
)
