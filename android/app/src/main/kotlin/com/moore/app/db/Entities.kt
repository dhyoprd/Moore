// contractId: SC-foundation@1.0.0 (+ 0002..0009 healing migrations)
// Room entities mirroring the shared .sql schema byte-for-byte (column names
// verbatim from the migrations; camelCase per SC-foundation §3).
// Naming map per #31: GRDB row struct ↔ Room @Entity data class.
package com.moore.app.db

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "folder")
data class FolderEntity(
    @PrimaryKey val id: String,
    val name: String,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String?,
)

@Entity(tableName = "exercise")
data class ExerciseEntity(
    @PrimaryKey val id: String,
    val name: String,
    val exerciseType: String,
    val equipmentSlug: String?,
    val primaryMuscleId: String?,
    val secondaryMuscleIdsJson: String?,
    val instructions: String?,
    val isCustom: Int,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String?,
    /// 0004 (rewritten, #32): SC-exercises §3b category; drives rest dispatch,
    /// the progression increment rule, and the Analytics muscle split. NULL = unclassified.
    val category: String?,
    /// 0004: 'reps' or 'duration' (CHECK); NULL = unset.
    val defaultMetric: String?,
    /// 0004: BR-009 per-exercise rest override (seconds); NULL = inherit.
    val defaultRestSec: Int?,
    /// 0004: BR-001 materialized normalized name (snake_case column by contract).
    @ColumnInfo(name = "name_normalized") val nameNormalized: String?,
)

@Entity(tableName = "routine")
data class RoutineEntity(
    @PrimaryKey val id: String,
    val folderId: String?,
    val name: String,
    val sortOrder: Int,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String?,
    /// Level-3 rest override (0008_rest_fields); NULL = inherit.
    val restSec: Int?,
)

@Entity(tableName = "planned_set")
data class PlannedSetEntity(
    @PrimaryKey val id: String,
    val routineId: String,
    val exerciseId: String,
    val sortOrder: Int,
    val plannedWeight: Double?,
    val plannedReps: Int?,
    val plannedDuration: Int?,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String?,
    /// 0002: warmup|work, NULL from pre-0002 rows (INV-6 coalesce → work).
    val setClass: String?,
    /// Level-1 rest override (0008_rest_fields); NULL = inherit.
    val restDurationSec: Int?,
)

@Entity(tableName = "workout_session")
data class WorkoutSessionEntity(
    @PrimaryKey val id: String,
    val startedAt: String,
    val endedAt: String?,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String?,
    /// 0003 import columns.
    val name: String?,
    val notes: String?,
    val importSource: String?,
    val importKey: String?,
    /// 0006 routine link (ad-hoc sessions NULL).
    val routineId: String?,
)

@Entity(tableName = "completed_set")
data class CompletedSetEntity(
    @PrimaryKey val id: String,
    val sessionId: String,
    val exerciseId: String,
    val sortOrder: Int,
    val plannedWeight: Double?,
    val plannedReps: Int?,
    val plannedDuration: Int?,
    val actualWeight: Double?,
    val actualReps: Int?,
    val actualDuration: Int?,
    val status: String,
    val completedAt: String?,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String?,
    /// 0002: warmup|work, NULL coalesces to work (INV-6).
    val setClass: String?,
)

/// Post-0008 canonical shape (sessionId present; kind ∈ max_*).
@Entity(tableName = "personal_record")
data class PersonalRecordEntity(
    @PrimaryKey val id: String,
    val exerciseId: String,
    val sessionId: String,
    val setId: String?,
    val kind: String,
    val value: Double,
    val achievedAt: String,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String?,
)

/// Post-0009 canonical shape (label column; free unit; kind ∈ bodyWeight|bodyFat|measurement).
@Entity(tableName = "body_metric")
data class BodyMetricEntity(
    @PrimaryKey val id: String,
    val kind: String,
    val label: String?,
    val value: Double,
    val unit: String,
    val recordedAt: String,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String?,
)

/// Post-0007_progression_full canonical shape.
@Entity(tableName = "progression_scheme")
data class ProgressionSchemeEntity(
    @PrimaryKey val id: String,
    val routineId: String,
    val exerciseId: String,
    val scheme: String,
    val incrementValue: Double?,
    val doubleProgressionMinReps: Int?,
    val doubleProgressionMaxReps: Int?,
    val warmupEnabled: Int,
    val stallCount: Int,
    val stallMuted: Int,
    val nextBannerAt: Int,
    val deloadPending: Int,
    val lastDeloadSessionId: String?,
    val stalledWeight: Double?,
    val stalledReps: Int?,
    val stalledDurationSec: Int?,
    val baselineDurationSec: Int?,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String?,
)

/// Singleton key-value rows (0008_rest_fields; SC-settings BR-001 the ONLY write).
@Entity(tableName = "app_setting")
data class AppSettingEntity(
    @PrimaryKey val key: String,
    val value: String,
    val updatedAt: String,
)

/// 0008_warmup chain marker table.
@Entity(tableName = "warmup_contract_scaffold")
data class WarmupScaffoldEntity(
    @PrimaryKey val id: String,
    val contractId: String,
    val version: String,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String?,
)
