// contractId: SC-routines @1.0.0
// Models: Routine row + PlannedSet row + Routine lifecycle + editor draft structs
// + Folder row + Home surface read model (§5).
// Mechanical Kotlin port of Sources/MooreRoutines/{Routine,Folder,HomeSurfaceViewModel}.swift.
// Timestamps are ISO-8601 UTC text (the shared .sql storage format).
package com.moore.routines

import com.moore.foundation.SetClass
import com.moore.foundation.roundAwayFromZero

/// Routine lifecycle (SC-routines §2a). Derived from the persisted row, never stored:
/// a row with deletedAt == null is draft until its first session start flips it to
/// active; deletedAt != null is tombstoned.
enum class RoutineLifecycle(val raw: String) {
    DRAFT("draft"), ACTIVE("active"), TOMBSTONED("tombstoned");
}

/// A single row of the routine table (in memory).
data class Routine(
    var id: String,              // UUID v4, lowercase-hyphenated (INV-1)
    var folderId: String? = null, // NULL = unfiled; 0..1 folder, cosmetic (INV-R3)
    var name: String,
    var sortOrder: Int = 0,
    var createdAt: String,
    var updatedAt: String,
    var deletedAt: String? = null, // tombstone (INV-3); null while live
) {
    /// Lifecycle (§2a): tombstoned if deleted, draft if never started, else active.
    /// hasSession = whether any session references this routine (workout_session.routineId).
    fun lifecycle(hasSession: Boolean): RoutineLifecycle {
        if (deletedAt != null) return RoutineLifecycle.TOMBSTONED
        return if (hasSession) RoutineLifecycle.ACTIVE else RoutineLifecycle.DRAFT
    }

    /// True when tombstoned (INV-3). Lifecycle tombstoned ⇔ deletedAt != null.
    val isTombstoned: Boolean get() = deletedAt != null
}

/// One intended set inside a routine (SC-routines §3b). Snapshot source for a
/// session's plannedX columns at materialisation (§2b / INV-R5).
data class PlannedSet(
    var id: String,              // UUID v4 (INV-1)
    var routineId: String,
    var exerciseId: String,
    var sortOrder: Int,
    var plannedWeight: Double? = null,
    var plannedReps: Int? = null,
    var plannedDuration: Int? = null,   // seconds
    var setClass: SetClass? = null,     // INV-6: NULL from pre-0002 rows; readers coalesce → work
    var createdAt: String,
    var updatedAt: String,
    var deletedAt: String? = null,
)

/// A single row of the folder table. One level deep, routines-only, cosmetic —
/// zero behavioural effect (#3 / SC-routines §2c, INV-R3).
data class Folder(
    var id: String,
    var name: String,
    var createdAt: String,
    var updatedAt: String,
    var deletedAt: String? = null,
) {
    val isTombstoned: Boolean get() = deletedAt != null
}

// MARK: - Editor draft structs (§2a, V2)

/// A set row as held in the routine editor's in-progress buffer. Distinct from
/// the persisted PlannedSet: no timestamp/identity bookkeeping — only what the
/// user edits. applyChanges() maps these back onto PlannedSet rows.
data class EditableSetDraft(
    var id: String,              // pre-generated UUID; becomes PlannedSet.id on save
    var exerciseId: String,
    var plannedWeight: Double? = null,
    var plannedReps: Int? = null,
    var plannedDuration: Int? = null,   // seconds
    var setClass: SetClass = SetClass.WORK,
)

// MARK: - Home surface read-model value types (§3b)

/// One row of the active-session banner / quick-resume card. Present iff a
/// WorkoutSession with endedAt IS NULL exists (§5).
data class ActiveSessionSummary(
    var id: String,
    var routineId: String?,
    var routineName: String?,          // null for ad-hoc / Start-empty sessions
    var startedAt: String,
    var setsDone: Int,                 // completed sets so far
    var setsTotal: Int,                // total sets in the session
)

/// One routine row on Home (§3b). Derived; never persisted (INV-R4).
data class RoutineRow(
    var routine: Routine,
    var exerciseCount: Int,
    var lastUsedAt: String?,
    var lastSessionSetCount: Int?,
    var lastSessionVolumeKg: Double?,
    var lastSessionDescription: String?, // "{setCount} sets · {volumeKg} kg"; null when never used
    var startEnabled: Boolean,           // = exerciseCount > 0  (BR-001)
) {
    val id: String get() = routine.id
}

/// The whole Home bundle (§3b). The Surface's single read.
data class HomeSnapshot(
    var activeSession: ActiveSessionSummary?,
    var streakCount: Int?,               // null when zero completed sessions (BR-005)
    var routines: List<RoutineRow>,      // last-used desc, then name asc (BR-006)
    var folders: List<Folder>,           // live folders, name asc (BR-006)
)

/// Statistics for one completed session started from a routine.
data class SessionStats(
    var completedAt: String,
    var setCount: Int,
    var volumeKg: Double,
)

/// The WorkoutSession read seam the Home surface depends on (§5).
interface SessionStatsProviding {
    /// The single in-flight session, if any (endedAt IS NULL), for the resume card.
    fun activeSession(): ActiveSessionSummary?
    /// Every completed session's endedAt — feeds BR-005's streak.
    fun completedSessionDates(): List<String>
    /// The most recent completed session started from routineId.
    fun lastCompletedSessionStats(routineId: String): SessionStats?
}

/// DAO seams (GRDB DAO ↔ Kotlin interface — identical method names per #31 map).
interface RoutineDAO {
    fun fetchAll(): List<Routine>
    fun exerciseCount(routineId: String): Int
    fun create(name: String, folderId: String?, exerciseList: List<EditableSetDraft>): Routine
    fun update(id: String, name: String, setDrafts: List<EditableSetDraft>): Routine
}

interface FolderDAO {
    fun fetchAll(): List<Folder>
}

/// The Home surface's read seam (§5). Exactly one read.
interface HomeSurfaceReading {
    fun readModel(): HomeSnapshot
}

/// Builds HomeSnapshot from the DAOs. `now` is injectable so BR-005's streak and
/// BR-006's last-used ordering are deterministic under test.
class HomeSurfaceViewModel(
    private val routineDAO: RoutineDAO,
    private val folderDAO: FolderDAO,
    private val sessionStatsProvider: SessionStatsProviding,
    var now: () -> String = { java.time.Instant.now().toString() },
) : HomeSurfaceReading {

    override fun readModel(): HomeSnapshot {
        val routines = routineDAO.fetchAll()
        val folders = folderDAO.fetchAll()

        // Per-routine derivations.
        val rows = ArrayList<RoutineRow>(routines.size)
        for (routine in routines) {
            val count = routineDAO.exerciseCount(routine.id)
            val last = sessionStatsProvider.lastCompletedSessionStats(routine.id)
            val desc: String? = last?.let { sessionDescription(it.setCount, it.volumeKg) }
            rows.add(RoutineRow(
                routine = routine,
                exerciseCount = count,
                lastUsedAt = last?.completedAt,
                lastSessionSetCount = last?.setCount,
                lastSessionVolumeKg = last?.volumeKg,
                lastSessionDescription = desc,
                startEnabled = count > 0,        // BR-001
            ))
        }
        // BR-006: last-used desc, ties/never-used fall back to name asc.
        rows.sortWith { a, b ->
            val la = a.lastUsedAt
            val lb = b.lastUsedAt
            when {
                la != null && lb != null -> if (la != lb) lb.compareTo(la) else a.routine.name.compareTo(b.routine.name)
                la != null -> -1
                lb != null -> 1
                else -> a.routine.name.compareTo(b.routine.name)
            }
        }

        // Active session (quick-resume card).
        val active = sessionStatsProvider.activeSession()

        // Streak (BR-005).
        val completedDates = sessionStatsProvider.completedSessionDates()
        val streak = StreakCalculator.streakCount(completedDates, now())

        return HomeSnapshot(
            activeSession = active,
            streakCount = streak,
            routines = rows,
            folders = folders,
        )
    }

    companion object {
        /// §3b lastSessionDescription — the format the UI binds to home.routineRow_lastUsed.
        fun sessionDescription(setCount: Int, volumeKg: Double): String {
            val volume = roundAwayFromZero(volumeKg)
            val volumeStr = if (volume % 1.0 == 0.0) volume.toLong().toString()
            else String.format(java.util.Locale.US, "%.1f", volume)
            return "$setCount sets · $volumeStr kg"
        }
    }
}
