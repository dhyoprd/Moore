// Room @Dao layer — method names identical to the GRDB DAOs (#31 naming map:
// GRDB DAO ↔ Room @Dao with identical method signatures where practical).
package com.moore.app.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Update

// MARK: - FolderDAO (Sources/MooreRoutines/FolderDAO.swift)

@Dao
interface FolderDao {
    @Query("SELECT * FROM folder WHERE deletedAt IS NULL ORDER BY name ASC")
    fun fetchAll(): List<FolderEntity>

    @Query("SELECT * FROM folder WHERE id = :id AND deletedAt IS NULL")
    fun fetch(id: String): FolderEntity?

    @Query("SELECT * FROM folder WHERE id = :id")
    fun fetchIncludingTombstoned(id: String): FolderEntity?

    @Insert
    fun create(folder: FolderEntity)

    @Query("UPDATE folder SET name = :name, updatedAt = :now WHERE id = :id AND deletedAt IS NULL")
    fun rename(id: String, name: String, now: String)

    /// BR-003 folder delete: re-scope routines to unfiled, then tombstone.
    @Transaction
    fun tombstone(id: String, now: String) {
        rescopeRoutinesToUnfiled(folderId = id, now = now)
        tombstoneRow(id = id, now = now)
    }

    @Query("UPDATE routine SET folderId = NULL, updatedAt = :now WHERE folderId = :folderId AND deletedAt IS NULL")
    fun rescopeRoutinesToUnfiled(folderId: String, now: String)

    @Query("UPDATE folder SET deletedAt = :now, updatedAt = :now WHERE id = :id AND deletedAt IS NULL")
    fun tombstoneRow(id: String, now: String)
}

// MARK: - RoutineDAO (Sources/MooreRoutines/RoutineDAO.swift)

@Dao
interface RoutineDao {
    @Query("SELECT * FROM routine WHERE deletedAt IS NULL ORDER BY sortOrder ASC, name ASC")
    fun fetchAll(): List<RoutineEntity>

    @Query("SELECT * FROM routine WHERE id = :id AND deletedAt IS NULL")
    fun fetch(id: String): RoutineEntity?

    @Query("SELECT * FROM routine WHERE id = :id")
    fun fetchIncludingTombstoned(id: String): RoutineEntity?

    @Query("SELECT * FROM planned_set WHERE routineId = :routineId AND deletedAt IS NULL ORDER BY sortOrder ASC")
    fun fetchSets(routineId: String): List<PlannedSetEntity>

    @Query("SELECT COUNT(DISTINCT exerciseId) FROM planned_set WHERE routineId = :routineId AND deletedAt IS NULL")
    fun exerciseCount(routineId: String): Int

    @Insert
    fun insert(routine: RoutineEntity)

    @Query("UPDATE routine SET name = :name, folderId = :folderId, updatedAt = :now WHERE id = :id AND deletedAt IS NULL")
    fun update(id: String, name: String, folderId: String?, now: String)

    @Query("UPDATE routine SET deletedAt = :now, updatedAt = :now WHERE id = :id AND deletedAt IS NULL")
    fun tombstone(id: String, now: String)

    @Query("UPDATE routine SET folderId = :folderId, updatedAt = :now WHERE id = :routineId AND deletedAt IS NULL")
    fun moveToFolder(routineId: String, folderId: String?, now: String)
}

// MARK: - ExerciseDAO (Sources/MooreExercises/ExerciseDAO.swift)

@Dao
interface ExerciseDao {
    @Query("SELECT * FROM exercise WHERE id = :id AND deletedAt IS NULL")
    fun getById(id: String): ExerciseEntity?

    @Query("SELECT * FROM exercise WHERE deletedAt IS NULL ORDER BY name ASC")
    fun fetchAll(): List<ExerciseEntity>

    @Insert
    fun insertCustom(exercise: ExerciseEntity)

    @Query("UPDATE exercise SET deletedAt = :now, updatedAt = :now WHERE id = :id AND deletedAt IS NULL")
    fun tombstone(id: String, now: String)

    /// BR-010 restore (SC-settings): clears deletedAt on a tombstoned row.
    @Query("UPDATE exercise SET deletedAt = NULL, updatedAt = :now WHERE id = :id AND deletedAt IS NOT NULL")
    fun restore(id: String, now: String)
}

// MARK: - WorkoutSessionDAO (Sources/MooreWorkout/WorkoutSessionDAO.swift)

@Dao
interface WorkoutSessionDao {
    @Query("SELECT * FROM workout_session WHERE deletedAt IS NULL ORDER BY startedAt DESC")
    fun fetchAll(): List<WorkoutSessionEntity>

    @Query("SELECT * FROM workout_session WHERE id = :sessionId AND deletedAt IS NULL")
    fun fetch(sessionId: String): WorkoutSessionEntity?

    @Insert
    fun insert(session: WorkoutSessionEntity)

    /// INV-W8: endedAt stamped exactly once.
    @Query("UPDATE workout_session SET endedAt = :endedAt, updatedAt = :now WHERE id = :sessionId AND deletedAt IS NULL")
    fun finishSession(sessionId: String, endedAt: String, now: String)

    @Query("SELECT * FROM completed_set WHERE sessionId = :sessionId AND deletedAt IS NULL ORDER BY sortOrder ASC")
    fun fetchSets(sessionId: String): List<CompletedSetEntity>

    @Insert
    fun insertMaterializedSet(row: CompletedSetEntity)

    @Query("""
        UPDATE completed_set
           SET status = :status, actualWeight = :actualWeight, actualReps = :actualReps,
               actualDuration = :actualDuration, completedAt = :completedAt, updatedAt = :now
         WHERE id = :setId AND deletedAt IS NULL
    """)
    fun updateSetStatus(
        setId: String,
        status: String,
        actualWeight: Double?,
        actualReps: Int?,
        actualDuration: Int?,
        completedAt: String?,
        now: String,
    )
}

// MARK: - PersonalRecordDAO (Sources/MooreRecords/PersonalRecordDAO.swift)

@Dao
interface PersonalRecordDao {
    /// fetchBest: live baseline rows per kind for the PR engine's live path.
    @Query("SELECT * FROM personal_record WHERE exerciseId = :exerciseId AND deletedAt IS NULL")
    fun fetchBest(exerciseId: String): List<PersonalRecordEntity>

    @Query("SELECT * FROM personal_record WHERE sessionId = :sessionId AND deletedAt IS NULL")
    fun fetchSessionPRs(sessionId: String): List<PersonalRecordEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun recordPR(pr: PersonalRecordEntity)

    @Query("""
        UPDATE personal_record
           SET value = :value, setId = :setId, sessionId = :sessionId,
               achievedAt = :achievedAt, updatedAt = :now
         WHERE id = :id AND deletedAt IS NULL
    """)
    fun rewriteHolder(id: String, value: Double, setId: String?, sessionId: String, achievedAt: String, now: String)

    @Query("UPDATE personal_record SET deletedAt = :now, updatedAt = :now WHERE id = :id AND deletedAt IS NULL")
    fun tombstone(id: String, now: String)
}

// MARK: - ProgressionDAO (Sources/MooreProgression/ProgressionDAO.swift)

@Dao
interface ProgressionDao {
    @Query("""
        SELECT * FROM progression_scheme
         WHERE routineId = :routineId AND exerciseId = :exerciseId AND deletedAt IS NULL
         LIMIT 1
    """)
    fun scheme(routineId: String, exerciseId: String): ProgressionSchemeEntity?

    /// #32 AC-3 seam: resolve exercise.category from the database for the
    /// engine's increment rule (BR-009: legs/lower +5kg, upper +2.5kg,
    /// ambiguous upper-biased). NULL/missing → the engine's upper-biased default.
    @Query("SELECT category FROM exercise WHERE id = :exerciseId")
    fun exerciseCategory(exerciseId: String): String?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun save(row: ProgressionSchemeEntity)
}

// MARK: - RestCycleDAO (Sources/MooreRest/RestCycleDAO.swift) + SettingsDAO seam

@Dao
interface AppSettingDao {
    @Query("SELECT value FROM app_setting WHERE key = :key")
    fun valueFor(key: String): String?

    /// SC-rest INV-S2 / SC-settings BR-005 upsert.
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(setting: AppSettingEntity)
}

// MARK: - WarmupDAO (Sources/MooreWarmup/WarmupDAO.swift)

@Dao
interface WarmupDao {
    /// BR-010 gate: warm-up ramps default OFF.
    @Query("""
        SELECT warmupEnabled FROM progression_scheme
         WHERE routineId = :routineId AND exerciseId = :exerciseId AND deletedAt IS NULL
         LIMIT 1
    """)
    fun warmupEnabledRaw(routineId: String, exerciseId: String): Int?

    fun warmupEnabled(routineId: String?, exerciseId: String): Boolean {
        if (routineId == null) return false
        return (warmupEnabledRaw(routineId, exerciseId) ?: 0) == 1
    }

    /// BR-009: snapshot immutability — a pair that already carries warm-up rows.
    @Query("""
        SELECT COUNT(*) FROM completed_set
         WHERE sessionId = :sessionId AND exerciseId = :exerciseId
           AND setClass = 'warmup' AND deletedAt IS NULL
    """)
    fun sessionWarmupRowCount(sessionId: String, exerciseId: String): Int

    fun sessionHasClassifiedWarmup(sessionId: String, exerciseId: String): Boolean =
        sessionWarmupRowCount(sessionId, exerciseId) > 0
}

// MARK: - AnalyticsDAO (read-only; Sources/MooreAnalytics/AnalyticsDAO.swift)

@Dao
interface AnalyticsDao {
    @Query("SELECT id, name, startedAt, endedAt FROM workout_session WHERE deletedAt IS NULL ORDER BY startedAt ASC")
    fun fetchSessions(): List<AnalyticsSessionRow>

    @Query("""
        SELECT id, sessionId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration,
               actualWeight, actualReps, actualDuration, status, setClass, completedAt
          FROM completed_set WHERE deletedAt IS NULL ORDER BY sessionId, sortOrder ASC
    """)
    fun fetchSets(): List<AnalyticsSetRow>

    @Query("SELECT id, exerciseId, sessionId, kind, value, achievedAt FROM personal_record WHERE deletedAt IS NULL ORDER BY achievedAt DESC")
    fun fetchPRRows(): List<AnalyticsPRRow>
}

data class AnalyticsSessionRow(
    val id: String,
    val name: String?,
    val startedAt: String,
    val endedAt: String?,
)

data class AnalyticsSetRow(
    val id: String,
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
    val setClass: String?,
    val completedAt: String?,
)

data class AnalyticsPRRow(
    val id: String,
    val exerciseId: String,
    val sessionId: String,
    val kind: String,
    val value: Double,
    val achievedAt: String,
)
