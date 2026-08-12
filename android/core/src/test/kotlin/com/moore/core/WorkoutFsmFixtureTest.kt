// SC-workout-logging@1.0.0 fixture runner (ticket #31 Stage A).
// Kotlin mirror of Tests/MooreWorkoutTests/VerifyWorkoutFsm.mjs: fresh
// in-memory DB per fixture (migrations 0001â€“0006); the SAME action lists run
// through the ported com.moore.workout.WorkoutSessionFSM and the harness
// persists the transitions the way WorkoutSessionDAO does.
package com.moore.core

import com.moore.foundation.SetClass
import com.moore.foundation.SetStatus
import com.moore.workout.FsmAction
import com.moore.workout.SetSnapshot
import com.moore.workout.TransitionResult
import com.moore.workout.WorkoutSessionFSM
import com.moore.test.Checks
import com.moore.test.Fixtures
import com.moore.test.MigrationChain
import com.moore.test.TestDb
import com.moore.test.obj
import com.moore.test.strOrNull
import org.junit.Test
import java.util.UUID

class WorkoutFsmFixtureTest {

    private val fixedNow = "2026-08-12T12:00:00Z"

    private val fixtureNames = listOf(
        "01-materialization.json",
        "02-one-tap-accept.json",
        "03-fail-records-actuals.json",
        "04-drop-plus-undo.json",
        "05-undo-expiry.json",
        "06-add-set-prefill.json",
        "07-edit-after-complete-no-rest.json",
        "08-superset-interleave.json",
        "09-finish-when-all-terminal.json",
        "10-dropped-never-requests-rest.json",
    )

    // MARK: - DB helpers (mirror VerifyWorkoutFsm.mjs)

    private class Materialized(val sessionId: String, val setIds: MutableList<String>)

    private fun materialize(db: TestDb, fixture: com.google.gson.JsonObject): Materialized {
        val ts = fixedNow
        for (eEl in fixture["exercises"].asJsonArray) {
            val e = eEl.obj
            db.insert("exercise", mapOf("id" to e["id"].asString, "name" to e["name"].asString,
                "exerciseType" to "strength", "isCustom" to 0, "createdAt" to ts, "updatedAt" to ts))
        }
        val r = fixture["routine"].obj
        db.insert("routine", mapOf("id" to r["id"].asString, "name" to r["name"].asString,
            "sortOrder" to 0, "createdAt" to ts, "updatedAt" to ts))
        r["sets"].asJsonArray.forEachIndexed { i, sEl ->
            val s = sEl.obj
            db.insert("planned_set", mapOf(
                "id" to UUID.randomUUID().toString(), "routineId" to r["id"].asString,
                "exerciseId" to s["exerciseId"].asString, "sortOrder" to i,
                "plannedWeight" to s["plannedWeight"].let { if (it.isJsonNull) null else it.asDouble },
                "plannedReps" to s["plannedReps"].let { if (it.isJsonNull) null else it.asInt },
                "plannedDuration" to s["plannedDuration"].let { if (it.isJsonNull) null else it.asInt },
                "setClass" to s["setClass"].strOrNull(), "createdAt" to ts, "updatedAt" to ts))
        }
        // Materialize.swift's copy (plannedX verbatim, actualX NULL, status planned).
        val sessionId = UUID.randomUUID().toString()
        db.insert("workout_session", mapOf("id" to sessionId, "routineId" to r["id"].asString,
            "startedAt" to ts, "createdAt" to ts, "updatedAt" to ts))
        val planned = db.query(
            "SELECT * FROM planned_set WHERE routineId = ? AND deletedAt IS NULL ORDER BY sortOrder", r["id"].asString)
        val setIds = mutableListOf<String>()
        planned.forEachIndexed { i, p ->
            val id = UUID.randomUUID().toString()
            setIds.add(id)
            db.insert("completed_set", mapOf(
                "id" to id, "sessionId" to sessionId, "exerciseId" to p["exerciseId"],
                "sortOrder" to i, "plannedWeight" to p["plannedWeight"],
                "plannedReps" to p["plannedReps"], "plannedDuration" to p["plannedDuration"],
                "actualWeight" to null, "actualReps" to null, "actualDuration" to null,
                "status" to "planned", "setClass" to p["setClass"],
                "createdAt" to ts, "updatedAt" to ts))
        }
        return Materialized(sessionId, setIds)
    }

    private fun persistTerminal(db: TestDb, setId: String, mirrorSet: SetSnapshot) {
        db.update("""
            UPDATE completed_set SET status = ?, actualWeight = ?, actualReps = ?, actualDuration = ?,
                completedAt = ?, updatedAt = ? WHERE id = ?
        """.trimIndent(), mirrorSet.status.raw, mirrorSet.actualWeight, mirrorSet.actualReps,
            mirrorSet.actualDurationSec, mirrorSet.completedAt, fixedNow, setId)
    }

    private fun persistDrop(db: TestDb, setId: String) {
        db.update("UPDATE completed_set SET status = 'dropped', updatedAt = ? WHERE id = ?", fixedNow, setId)
    }

    private fun persistUndo(db: TestDb, setId: String) {
        db.update("UPDATE completed_set SET status = 'planned', updatedAt = ? WHERE id = ?", fixedNow, setId)
    }

    private fun persistAddSet(db: TestDb, sessionId: String, mirrorSet: SetSnapshot) {
        db.insert("completed_set", mapOf(
            "id" to mirrorSet.id, "sessionId" to sessionId, "exerciseId" to mirrorSet.exerciseId,
            "sortOrder" to mirrorSet.sortOrder, "plannedWeight" to mirrorSet.plannedWeight,
            "plannedReps" to mirrorSet.plannedReps, "plannedDuration" to mirrorSet.plannedDurationSec,
            "actualWeight" to null, "actualReps" to null, "actualDuration" to null,
            "status" to "planned", "setClass" to mirrorSet.setClass?.raw,
            "createdAt" to fixedNow, "updatedAt" to fixedNow))
    }

    private fun rowToSnapshot(row: Map<String, Any?>): SetSnapshot = SetSnapshot(
        id = row["id"] as String,
        exerciseId = row["exerciseId"] as String,
        sortOrder = (row["sortOrder"] as Number).toInt(),
        status = SetStatus.fromRaw(row["status"] as String),
        plannedWeight = (row["plannedWeight"] as? Number)?.toDouble(),
        plannedReps = (row["plannedReps"] as? Number)?.toInt(),
        plannedDurationSec = (row["plannedDuration"] as? Number)?.toInt(),
        actualWeight = (row["actualWeight"] as? Number)?.toDouble(),
        actualReps = (row["actualReps"] as? Number)?.toInt(),
        actualDurationSec = (row["actualDuration"] as? Number)?.toInt(),
        setClass = SetClass.fromRaw(row["setClass"] as String?),
        completedAt = row["completedAt"] as String?,
    )

    // MARK: - Runner

    private fun runFixture(checks: Checks, name: String) {
        val fixture = Fixtures.json("workout", name)
        TestDb().use { db ->
            db.applyAll(*MigrationChain.WORKOUT_FULL)

            var sessionId: String? = null
            val setIds = mutableListOf<String>()
            var fsm: WorkoutSessionFSM? = null
            val cues = mutableListOf<String>()
            val tag = "[$name]"

            for (actionEl in fixture["actions"].asJsonArray) {
                val action = actionEl.obj
                when (action["type"].asString) {
                    "materialize" -> {
                        val m = materialize(db, fixture)
                        sessionId = m.sessionId
                        setIds.addAll(m.setIds)
                        val rows = db.query(
                            "SELECT * FROM completed_set WHERE sessionId = ? ORDER BY sortOrder", sessionId)
                        fsm = WorkoutSessionFSM(sessionId!!, rows.map { rowToSnapshot(it) }) { fixedNow }
                    }
                    else -> {
                        val i = action["setIndex"]?.asInt
                        val f = fsm!!
                        when (action["type"].asString) {
                            "accept" -> {
                                val res = f.dispatch(FsmAction.Accept(setIds[i!!]))
                                if (res is TransitionResult.Success) {
                                    res.emitted.forEach { cues.add(it.raw) }
                                    persistTerminal(db, setIds[i], f.state.sets[i])
                                }
                            }
                            "fail" -> {
                                val res = f.dispatch(FsmAction.Fail(setIds[i!!],
                                    action["actualWeight"]?.let { if (it.isJsonNull) null else it.asDouble },
                                    action["actualReps"]?.let { if (it.isJsonNull) null else it.asInt },
                                    action["actualDuration"]?.let { if (it.isJsonNull) null else it.asInt }))
                                if (res is TransitionResult.Success) {
                                    res.emitted.forEach { cues.add(it.raw) }
                                    persistTerminal(db, setIds[i], f.state.sets[i])
                                }
                            }
                            "editCompleted" -> {
                                val res = f.dispatch(FsmAction.EditCompleted(setIds[i!!],
                                    action["actualWeight"]?.let { if (it.isJsonNull) null else it.asDouble },
                                    action["actualReps"]?.let { if (it.isJsonNull) null else it.asInt },
                                    action["actualDuration"]?.let { if (it.isJsonNull) null else it.asInt }))
                                if (res is TransitionResult.Success) {
                                    res.emitted.forEach { cues.add(it.raw) }
                                    persistTerminal(db, setIds[i], f.state.sets[i])
                                }
                            }
                            "drop" -> {
                                val res = f.dispatch(FsmAction.Drop(setIds[i!!]))
                                if (res is TransitionResult.Success) {
                                    res.emitted.forEach { cues.add(it.raw) }
                                    persistDrop(db, setIds[i])
                                }
                            }
                            "undoDrop" -> {
                                val res = f.dispatch(FsmAction.UndoDrop(setIds[i!!]))
                                if (action["expectFailure"]?.asBoolean == true) {
                                    checks.ok(res is TransitionResult.Failure, "$tag undoDrop refused (window closed)")
                                } else if (res is TransitionResult.Success) {
                                    res.emitted.forEach { cues.add(it.raw) }
                                    persistUndo(db, setIds[i])
                                } else {
                                    checks.fail("$tag undoDrop unexpectedly refused")
                                }
                            }
                            "addSet" -> {
                                val res = f.dispatch(FsmAction.AddSet(action["exerciseId"].asString))
                                if (res is TransitionResult.Success) {
                                    res.emitted.forEach { cues.add(it.raw) }
                                    val newSet = f.state.sets.last()
                                    persistAddSet(db, sessionId!!, newSet)
                                    setIds.add(newSet.id)
                                }
                            }
                            "finishSession" -> {
                                val res = f.dispatch(FsmAction.FinishSession)
                                if (res is TransitionResult.Success) {
                                    res.emitted.forEach { cues.add(it.raw) }
                                    db.update("UPDATE workout_session SET endedAt = ?, updatedAt = ? WHERE id = ?",
                                        f.state.finishedAt, fixedNow, sessionId)
                                }
                            }
                            else -> checks.fail("$tag unknown action ${action["type"].asString}")
                        }
                    }
                }
            }

            // ---- DB assertions ----
            val exp = fixture["expect"].obj
            val rows = db.query(
                "SELECT * FROM completed_set WHERE sessionId = ? ORDER BY sortOrder", sessionId)
            checks.eq(rows.size, exp["setCount"].asInt, "$tag DB.setCount")

            exp["sets"]?.asJsonArray?.forEachIndexed { idx, eEl ->
                val e = eEl.obj
                val r = rows.getOrNull(idx)
                if (r == null) {
                    checks.fail("$tag set[$idx] missing")
                    return@forEachIndexed
                }
                for (k in listOf("status", "exerciseId", "sortOrder", "plannedWeight", "plannedReps",
                    "actualWeight", "actualReps", "actualDuration")) {
                    if (e.has(k)) {
                        val expected = Checks.toKotlin(e[k])
                        val actual = when (k) {
                            "sortOrder" -> (r[k] as? Number)?.toInt()
                            "plannedReps", "actualReps" -> (r[k] as? Number)?.toInt()
                            "plannedWeight", "actualWeight" -> (r[k] as? Number)?.toDouble()
                            "actualDuration" -> (r[k] as? Number)?.toInt()
                            else -> r[k]
                        }
                        checks.ok(Checks.looseEquals(actual, expected),
                            "$tag set[$idx].$k == $expected (got $actual)")
                    }
                }
                if (e["completedAtNonNull"]?.asBoolean == true) {
                    checks.ok(r["completedAt"] != null, "$tag set[$idx].completedAt stamped")
                }
            }

            // ---- Snapshot assertions ----
            val snap = exp["snapshot"]?.obj
            val f = fsm!!
            if (snap != null) {
                if (snap.has("overlayState")) {
                    checks.eq(f.state.overlayState.raw, snap["overlayState"].asString, "$tag snapshot.overlayState")
                }
                if (snap.has("restRequested")) {
                    checks.eq(f.state.restRequested, snap["restRequested"].asBoolean, "$tag snapshot.restRequested")
                }
                if (snap.has("finishReady")) {
                    checks.eq(f.state.allSetsTerminal, snap["finishReady"].asBoolean, "$tag snapshot.finishReady")
                }
                if (snap["lastCompletedSetIsSet0"]?.asBoolean == true) {
                    checks.eq(f.state.lastCompletedSetId, setIds[0], "$tag snapshot.lastCompletedSetId == set0")
                }
                if (snap["nextIncompleteIsSet1"]?.asBoolean == true) {
                    checks.eq(f.state.nextIncompleteSetId, setIds[1], "$tag snapshot.nextIncompleteSetId == set1")
                }
                if (snap["nextIncompleteIsSet0"]?.asBoolean == true) {
                    checks.eq(f.state.nextIncompleteSetId, setIds[0], "$tag snapshot.nextIncompleteSetId == set0")
                }
                if (snap["nextIncompleteNull"]?.asBoolean == true) {
                    checks.eq(f.state.nextIncompleteSetId, null, "$tag snapshot.nextIncompleteSetId == null")
                }
                if (snap["undoCleared"]?.asBoolean == true) {
                    checks.eq(f.state.undoableDrop, null, "$tag snapshot.undoableDrop cleared after undo")
                }
            }

            // ---- Cue assertions ----
            val expectedCues = exp["cues"]?.takeIf { it.isJsonArray }?.asJsonArray?.map { it.asString }
            if (expectedCues != null) {
                checks.eq(cues, expectedCues, "$tag cues")
            }
            if (exp["cuesNotReemitted"]?.asBoolean == true) {
                val count = cues.count { it == "cue.set.completed" }
                checks.eq(count, 1, "$tag cue.set.completed emitted exactly once (edit-after-complete silent)")
            }
            if (exp["sessionEndedNonNull"]?.asBoolean == true) {
                val s = db.queryOne("SELECT endedAt FROM workout_session WHERE id = ?", sessionId)
                checks.ok(s?.get("endedAt") != null, "$tag session.endedAt stamped")
            }
        }
    }

    @Test
    fun `all workout FSM fixtures pass on the ported state machine`() {
        val checks = Checks("WorkoutFsm")
        for (f in fixtureNames) {
            runFixture(checks, f)
        }
        checks.flush()
    }
}

