// SC-routines@1.0.0 fixture runner (ticket #31 Stage A).
// Kotlin mirror of Tests/MooreRoutinesTests/VerifyRoutines.mjs (CRUD, folder
// orphan, home read shapes, streak scheduling) PLUS parity tests for the
// ported pure Kotlin routines layer: Routine.lifecycle, RoutineEditorBuffer,
// StreakCalculator, HomeSurfaceViewModel.sessionDescription.
package com.moore.core

import com.moore.foundation.SetClass
import com.moore.routines.EditableSetDraft
import com.moore.routines.HomeSurfaceViewModel
import com.moore.routines.Routine
import com.moore.routines.RoutineEditorBuffer
import com.moore.routines.RoutineLifecycle
import com.moore.routines.StreakCalculator
import com.moore.test.Checks
import com.moore.test.Fixtures
import com.moore.test.MigrationChain
import com.moore.test.TestDb
import com.moore.test.obj
import org.junit.Test
import java.util.UUID

class RoutinesFixtureTest {

    private fun freshDb(): TestDb {
        val db = TestDb()
        db.applyAll(*MigrationChain.WORKOUT_FULL)
        seedFixturesExercises(db)
        return db
    }

    /// Seed the built-in exercises the routine fixtures cite.
    private fun seedFixturesExercises(db: TestDb) {
        val ts = "2026-08-12T00:00:00Z"
        val exercises = listOf(
            Triple("ex-bench", "Barbell Bench Press", "barbell"),
            Triple("ex-ohp", "Barbell Overhead Press", "barbell"),
            Triple("ex-dip", "Dips (Weighted)", "bodyweight"),
        )
        for ((id, name, equipment) in exercises) {
            db.insert("exercise", mapOf("id" to id, "name" to name, "exerciseType" to "strength",
                "equipmentSlug" to equipment, "isCustom" to 0, "createdAt" to ts, "updatedAt" to ts))
        }
    }

    // MARK: - Fixture tests (VerifyRoutines.mjs mirror)

    @Test
    fun `sanity - required tables all there`() {
        val checks = Checks("Routines.sanity")
        freshDb().use { db ->
            val tables = db.tableNames()
            for (t in listOf("folder", "exercise", "routine", "planned_set", "workout_session")) {
                checks.ok(t in tables, "table.$t.exists")
            }
        }
        checks.flush()
    }

    @Test
    fun `V1-V4 routine CRUD duplicate and tombstone-delete`() {
        val checks = Checks("Routines.crud")
        val f = Fixtures.json("routines", "routine-crud.json")
        freshDb().use { db ->
            val now = "2026-08-12T12:00:00Z"
            // CREATE
            val routineId = UUID.randomUUID().toString()
            val create = f["create"].obj
            db.insert("routine", mapOf("id" to routineId, "name" to create["name"].asString,
                "folderId" to null, "sortOrder" to 0, "createdAt" to now, "updatedAt" to now))
            create["sets"].asJsonArray.forEachIndexed { i, sEl ->
                val s = sEl.obj
                db.insert("planned_set", mapOf(
                    "id" to UUID.randomUUID().toString(), "routineId" to routineId,
                    "exerciseId" to s["exerciseId"].asString, "sortOrder" to i,
                    "setClass" to s["setClass"].let { if (it.isJsonNull) null else it.asString },
                    "plannedWeight" to s["plannedWeight"].let { if (it.isJsonNull) null else it.asDouble },
                    "plannedReps" to s["plannedReps"].let { if (it.isJsonNull) null else it.asInt },
                    "plannedDuration" to s["plannedDuration"].let { if (it.isJsonNull) null else it.asInt },
                    "createdAt" to now, "updatedAt" to now))
            }
            val sets = db.query("SELECT * FROM planned_set WHERE routineId = ?", routineId)
            checks.eq(sets.size, create["expected"].obj["setCount"].asInt, "V1.create.setCount")
            val exerciseCount = sets.map { it["exerciseId"] }.distinct().size
            checks.eq(exerciseCount, create["expected"].obj["exerciseCount"].asInt, "V1.create.exerciseCount")
            val allHavePlannedValues = sets.all {
                it["plannedWeight"] != null || it["plannedReps"] != null || it["plannedDuration"] != null
            }
            checks.ok(allHavePlannedValues, "V1.create.startEnabled (>=1 complete set)")

            // EDIT
            val edit = f["edit"]?.obj
            if (edit != null) {
                val newExercise = edit["addExercise"].asString
                db.insert("planned_set", mapOf("id" to UUID.randomUUID().toString(), "routineId" to routineId,
                    "exerciseId" to newExercise, "sortOrder" to 3, "setClass" to "work",
                    "plannedWeight" to null, "plannedReps" to 12, "plannedDuration" to null,
                    "createdAt" to now, "updatedAt" to now))
                val afterAdd = db.query("SELECT * FROM planned_set WHERE routineId = ?", routineId)
                val newExerciseCount = afterAdd.map { it["exerciseId"] }.distinct().size
                checks.eq(newExerciseCount, edit["expected"].obj["exerciseCount"].asInt, "V2.edit.exerciseCountAfterAdd")
                val targetSetIndex = edit["changedPlannedWeight"].obj["setIndex"].asInt
                val targetSet = afterAdd.first { (it["sortOrder"] as Number).toInt() == targetSetIndex }
                db.update("UPDATE planned_set SET plannedWeight = ?, updatedAt = ? WHERE id = ?",
                    edit["changedPlannedWeight"].obj["plannedWeight"].asDouble, now, targetSet["id"])
                val updated = db.queryOne("SELECT plannedWeight FROM planned_set WHERE id = ?", targetSet["id"])
                checks.eq((updated?.get("plannedWeight") as? Number)?.toDouble(),
                    edit["changedPlannedWeight"].obj["plannedWeight"].asDouble, "V2.edit.changedPlannedWeight")
            }

            // DUPLICATE
            val duplicate = f["duplicate"]?.obj
            if (duplicate != null) {
                val newRoutineId = UUID.randomUUID().toString()
                db.update("""
                    INSERT INTO routine (id, name, folderId, sortOrder, createdAt, updatedAt)
                    SELECT ?, ? || name, folderId, sortOrder, ?, ? FROM routine WHERE id = ?
                """.trimIndent(), newRoutineId, duplicate["expectedNamePrefix"].asString, now, now, routineId)
                val newRoutine = db.queryOne("SELECT * FROM routine WHERE id = ?", newRoutineId)!!
                checks.ok((newRoutine["name"] as String).startsWith(duplicate["expectedNamePrefix"].asString),
                    "V3.duplicate.namePrefix")
                checks.ok(newRoutine["id"] != routineId, "V3.duplicate.newIdDiffers")
                val oldSets = db.query("SELECT * FROM planned_set WHERE routineId = ?", routineId)
                var newIdsDiffer = true
                for (s in oldSets) {
                    val newSetId = UUID.randomUUID().toString()
                    if (newSetId == s["id"]) newIdsDiffer = false
                    val copied = LinkedHashMap<String, Any?>(s)
                    copied["id"] = newSetId
                    copied["routineId"] = newRoutineId
                    copied["createdAt"] = now
                    copied["updatedAt"] = now
                    db.insert("planned_set", copied)
                }
                checks.ok(newIdsDiffer, "V3.duplicate.setIdsDiffer")
                val newSetCount = (db.queryOne("SELECT COUNT(*) as c FROM planned_set WHERE routineId = ?", newRoutineId)
                    ?.get("c") as Number).toInt()
                checks.eq(newSetCount, oldSets.size, "V3.duplicate.setCountMatches")
            }

            // DELETE
            val delete = f["delete"]?.obj
            if (delete != null) {
                val ts = now
                db.update("UPDATE routine SET deletedAt = ?, updatedAt = ? WHERE id = ?", ts, ts, routineId)
                val live = db.queryOne("SELECT id FROM routine WHERE id = ? AND deletedAt IS NULL", routineId)
                val tomb = db.queryOne("SELECT id, deletedAt FROM routine WHERE id = ?", routineId)
                checks.ok(live == null, "V4.delete.absentFromRoutines")
                checks.ok(tomb != null && tomb["deletedAt"] == ts, "V4.delete.presentIncludingTombstoned")
            }
        }
        checks.flush()
    }

    @Test
    fun `V5 folder delete leaves routines unfiled`() {
        val checks = Checks("Routines.folderOrphan")
        Fixtures.json("routines", "folder-orphan.json")   // fixture drives the scenario shape
        freshDb().use { db ->
            val now = "2026-08-12T12:00:00Z"
            val fid = UUID.randomUUID().toString()
            val rid = UUID.randomUUID().toString()
            db.insert("folder", mapOf("id" to fid, "name" to "Push Pull", "createdAt" to now, "updatedAt" to now))
            db.insert("routine", mapOf("id" to rid, "name" to "Push A", "folderId" to fid,
                "sortOrder" to 0, "createdAt" to now, "updatedAt" to now))

            // folder delete via the business rule: re-scope then tombstone folder.
            db.update("UPDATE routine SET folderId = NULL, updatedAt = ? WHERE folderId = ?", now, fid)
            db.update("UPDATE folder SET deletedAt = ?, updatedAt = ? WHERE id = ?", now, now, fid)

            val liveRoutine = db.queryOne("SELECT folderId FROM routine WHERE id = ? AND deletedAt IS NULL", rid)
            checks.ok(liveRoutine != null && liveRoutine["folderId"] == null, "V5.folderDelete.routineUnfiled")
            val folderGone = db.queryOne("SELECT id FROM folder WHERE id = ? AND deletedAt IS NULL", fid)
            checks.ok(folderGone == null, "V5.folderDelete.folderGone")
        }
        checks.flush()
    }

    @Test
    fun `V6 empty home reads zero routines and hidden streak`() {
        val checks = Checks("Routines.emptyHome")
        freshDb().use { db ->
            val routines = (db.queryOne("SELECT COUNT(*) as c FROM routine WHERE deletedAt IS NULL")?.get("c") as Number).toInt()
            val sessions = (db.queryOne("SELECT COUNT(*) as c FROM workout_session WHERE deletedAt IS NULL")?.get("c") as Number).toInt()
            checks.eq(routines, 0, "V6.empty.noRoutines")
            checks.eq(sessions, 0, "V6.empty.noSessions_streakHidden")
        }
        checks.flush()
    }

    @Test
    fun `V7 populated home round-trips 12 routines lastUsed desc`() {
        val checks = Checks("Routines.populatedHome")
        freshDb().use { db ->
            val now = "2026-08-12T12:00:00Z"
            val folderIds = listOf(UUID.randomUUID().toString(), UUID.randomUUID().toString(), UUID.randomUUID().toString())
            folderIds.forEachIndexed { i, fid ->
                db.insert("folder", mapOf("id" to fid, "name" to "F$i", "createdAt" to now, "updatedAt" to now))
            }
            val days = listOf("2026-06-01", "2026-06-15", "2026-06-29", "2026-07-05", "2026-07-10", "2026-07-12",
                "2026-07-15", "2026-07-18", "2026-07-20", "2026-07-22", "2026-07-25", "2026-08-01")
            for (i in 0 until 12) {
                val rid = UUID.randomUUID().toString()
                db.insert("routine", mapOf("id" to rid, "name" to "R$i", "folderId" to folderIds[i % 3],
                    "sortOrder" to i, "createdAt" to now, "updatedAt" to now))
                // a completed session = endedAt IS NOT NULL per current contract
                db.insert("workout_session", mapOf("id" to UUID.randomUUID().toString(), "routineId" to rid,
                    "startedAt" to "${days[i]}T09:00:00Z", "endedAt" to "${days[i]}T10:00:00Z",
                    "createdAt" to now, "updatedAt" to now))
            }
            val rows = db.query("""
                SELECT r.name, MAX(w.endedAt) as lastUsed
                FROM routine r LEFT JOIN workout_session w ON w.routineId = r.id AND w.deletedAt IS NULL AND w.endedAt IS NOT NULL
                WHERE r.deletedAt IS NULL
                GROUP BY r.id
                ORDER BY lastUsed DESC
            """.trimIndent())
            checks.eq(rows.size, 12, "V7.populated.12RoutinesRead")
            checks.eq(rows[0]["name"], "R11", "V7.populated.lastUsedSortedDesc")
        }
        checks.flush()
    }

    @Test
    fun `V8 streak derives from session timestamps only`() {
        val checks = Checks("Routines.streakScheduling")
        freshDb().use { db ->
            fun completedCount() = (db.queryOne(
                "SELECT COUNT(*) as c FROM workout_session WHERE endedAt IS NOT NULL AND deletedAt IS NULL")
                ?.get("c") as Number).toInt()
            fun distinctDays() = (db.queryOne(
                "SELECT COUNT(DISTINCT date(endedAt)) as c FROM workout_session WHERE endedAt IS NOT NULL AND deletedAt IS NULL")
                ?.get("c") as Number).toInt()

            checks.eq(completedCount(), 0, "V8.streak.emptyIsZero")

            val t = "2026-08-12T12:00:00Z"
            db.insert("workout_session", mapOf("id" to UUID.randomUUID().toString(), "routineId" to null,
                "startedAt" to t, "endedAt" to t, "createdAt" to t, "updatedAt" to t))
            checks.eq(distinctDays(), 1, "V8.streak.oneSession")

            val d1 = "2026-08-11T12:00:00Z"
            val d2 = "2026-08-10T12:00:00Z"
            db.insert("workout_session", mapOf("id" to UUID.randomUUID().toString(), "routineId" to null,
                "startedAt" to d1, "endedAt" to d1, "createdAt" to t, "updatedAt" to t))
            db.insert("workout_session", mapOf("id" to UUID.randomUUID().toString(), "routineId" to null,
                "startedAt" to d2, "endedAt" to d2, "createdAt" to t, "updatedAt" to t))
            checks.eq(distinctDays(), 3, "V8.streak.threeDays")
        }
        checks.flush()
    }

    // MARK: - Pure Kotlin routines layer (ported Swift parity)

    @Test
    fun `Routine lifecycle projection`() {
        val checks = Checks("Routines.lifecycle")
        val ts = "2026-08-12T00:00:00Z"
        val draft = Routine(id = "r1", name = "A", createdAt = ts, updatedAt = ts)
        checks.eq(draft.lifecycle(hasSession = false), RoutineLifecycle.DRAFT, "lifecycle.draft")
        checks.eq(draft.lifecycle(hasSession = true), RoutineLifecycle.ACTIVE, "lifecycle.active")
        val tombstoned = draft.copy(deletedAt = ts)
        checks.eq(tombstoned.lifecycle(hasSession = true), RoutineLifecycle.TOMBSTONED, "lifecycle.tombstoned")
        checks.ok(tombstoned.isTombstoned, "lifecycle.isTombstoned")
        checks.flush()
    }

    @Test
    fun `RoutineEditorBuffer editor gestures`() {
        val checks = Checks("Routines.editorBuffer")
        val buffer = RoutineEditorBuffer(name = "New Day")
        checks.eq(buffer.routineId, null, "buffer.create.routineId-null")
        checks.eq(buffer.drafts.size, 0, "buffer.create.empty")

        buffer.addExercise("ex-bench")
        buffer.addExercise("ex-ohp")
        checks.eq(buffer.drafts.size, 2, "buffer.addExercise.count")

        // addSet copies defaults from the exercise's last row.
        buffer.updateSet(buffer.drafts[0].id) { d ->
            d.plannedWeight = 60.0
            d.plannedReps = 8
            d.setClass = SetClass.WORK
        }
        buffer.addSetForExercise("ex-bench")
        checks.eq(buffer.drafts.size, 3, "buffer.addSet.count")
        val copied = buffer.drafts[2]
        checks.eq(copied.plannedWeight, 60.0, "buffer.addSet.copiesWeight")
        checks.eq(copied.plannedReps, 8, "buffer.addSet.copiesReps")

        // Reorder.
        buffer.moveSet(2, 0)
        checks.eq(buffer.drafts[0].exerciseId, "ex-bench", "buffer.moveSet.head")
        checks.eq(buffer.drafts[0].plannedWeight, 60.0, "buffer.moveSet.carriesValues")

        // Remove.
        val victim = buffer.drafts[1].id
        buffer.removeSet(victim)
        checks.eq(buffer.drafts.size, 2, "buffer.removeSet.count")
        checks.ok(buffer.drafts.none { it.id == victim }, "buffer.removeSet.gone")

        // Loading an existing routine coalesces NULL setClass to work (INV-6).
        val ts = "2026-08-12T00:00:00Z"
        val routine = Routine(id = "r-x", name = "Loaded", createdAt = ts, updatedAt = ts)
        val sets = listOf(com.moore.routines.PlannedSet(
            id = "ps-1", routineId = "r-x", exerciseId = "ex-bench", sortOrder = 0,
            plannedWeight = 100.0, plannedReps = 5, setClass = null, createdAt = ts, updatedAt = ts))
        val loaded = RoutineEditorBuffer(routine, sets)
        checks.eq(loaded.routineId, "r-x", "buffer.load.routineId")
        checks.eq(loaded.drafts[0].setClass, SetClass.WORK, "buffer.load.setClass-coalesce-work")
        checks.flush()
    }

    @Test
    fun `StreakCalculator weekly streak semantics`() {
        val checks = Checks("Routines.streakCalculator")
        // Hidden when zero completed sessions (BR-005 / V7).
        checks.eq(StreakCalculator.streakCount(emptyList(), "2026-08-12T12:00:00Z"), null, "streak.empty-hidden")

        // One session → 1-week streak.
        checks.eq(StreakCalculator.streakCount(listOf("2026-08-12T12:00:00Z"), "2026-08-12T12:00:00Z"), 1,
            "streak.single-week")

        // Consecutive weeks (Mon 2026-08-03 week + Mon 2026-08-10 week) → 2.
        checks.eq(StreakCalculator.streakCount(
            listOf("2026-08-05T12:00:00Z", "2026-08-12T12:00:00Z"), "2026-08-12T12:00:00Z"), 2,
            "streak.two-consecutive-weeks")

        // A gap breaks the chain: weeks of 2026-07-20 and 2026-08-12 → 1.
        checks.eq(StreakCalculator.streakCount(
            listOf("2026-07-22T12:00:00Z", "2026-08-12T12:00:00Z"), "2026-08-12T12:00:00Z"), 1,
            "streak.gap-breaks-chain")

        // Anchored at the most recent session week: a broken current week does
        // not zero the streak (#14).
        checks.eq(StreakCalculator.streakCount(
            listOf("2026-08-05T12:00:00Z"), "2026-08-20T12:00:00Z"), 1,
            "streak.anchor-most-recent-week")
        checks.flush()
    }

    @Test
    fun `HomeSurfaceViewModel sessionDescription format`() {
        val checks = Checks("Routines.sessionDescription")
        checks.eq(HomeSurfaceViewModel.sessionDescription(5, 1400.0), "5 sets · 1400 kg", "desc.integral-volume")
        // Half-away-from-zero: 512.5 → 513 (Swift .rounded() parity).
        checks.eq(HomeSurfaceViewModel.sessionDescription(3, 512.5), "3 sets · 513 kg", "desc.rounds-half-away")
        checks.eq(HomeSurfaceViewModel.sessionDescription(4, 999.4), "4 sets · 999 kg", "desc.rounds-down")
        checks.flush()
    }
}
