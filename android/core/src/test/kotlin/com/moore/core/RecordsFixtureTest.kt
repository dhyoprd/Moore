// SC-prs@1.0.0 fixture runner (ticket #31 Stage A).
// Kotlin mirror of Tests/MooreRecordsTests/VerifyRecords.mjs: fresh in-memory
// DB per fixture; migrations 0001–0008; the writeFromSet / rederive harness
// mirrors PersonalRecordDAO.swift over the ported com.moore.records.PREngine.
package com.moore.core

import com.moore.foundation.SetClass
import com.moore.foundation.SetStatus
import com.moore.records.PRKind
import com.moore.records.PREngine
import com.moore.records.PersonalRecord
import com.moore.records.ReferenceSessionSet
import com.moore.records.SeamMetric
import com.moore.test.Checks
import com.moore.test.Fixtures
import com.moore.test.MigrationChain
import com.moore.test.TestDb
import com.moore.test.intOrNull
import com.moore.test.numOrNull
import com.moore.test.obj
import com.moore.test.strOrNull
import org.junit.Test
import java.util.UUID

class RecordsFixtureTest {

    // MARK: - Harness (mirrors VerifyRecords.mjs DB plumbing / PersonalRecordDAO)

    private val seedNow = "2026-08-12T00:00:00Z"
    private val writeNow = "2026-08-12T12:00:00Z"

    private fun newDb(): TestDb {
        val db = TestDb()
        db.applyAll(*MigrationChain.RECORDS_FULL)
        return db
    }

    private fun seedFixture(db: TestDb, fx: com.google.gson.JsonObject) {
        val seed = fx["seed"]?.obj ?: return
        seed["exercises"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val e = el.obj
            db.insert("exercise", mapOf(
                "id" to e["id"].asString, "name" to e["name"].asString,
                "exerciseType" to (e["exerciseType"].strOrNull() ?: "strength"),
                "isCustom" to 0, "createdAt" to seedNow, "updatedAt" to seedNow))
        }
        seed["sessions"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val s = el.obj
            db.insert("workout_session", mapOf(
                "id" to s["id"].asString, "startedAt" to s["startedAt"].asString,
                "endedAt" to s["endedAt"].strOrNull(), "createdAt" to seedNow, "updatedAt" to seedNow))
        }
        var ord = 0
        seed["sets"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val s = el.obj
            db.insert("completed_set", mapOf(
                "id" to s["id"].asString, "sessionId" to s["sessionId"].asString,
                "exerciseId" to s["exerciseId"].asString, "sortOrder" to ord++,
                "actualWeight" to s["actualWeight"].numOrNull(),
                "actualReps" to s["actualReps"].intOrNull(),
                "actualDuration" to s["actualDuration"].intOrNull(),
                "status" to s["status"].asString,
                "setClass" to s["setClass"].strOrNull(),
                "completedAt" to s["completedAt"].strOrNull(),
                "createdAt" to seedNow, "updatedAt" to seedNow))
        }
        seed["personalRecords"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val p = el.obj
            db.insert("personal_record", mapOf(
                "id" to UUID.randomUUID().toString(),
                "exerciseId" to p["exerciseId"].asString,
                "sessionId" to p["sessionId"].asString,
                "setId" to p["setId"].strOrNull(),
                "kind" to p["kind"].asString,
                "value" to p["value"].asDouble,
                "achievedAt" to p["achievedAt"].asString,
                "createdAt" to seedNow, "updatedAt" to seedNow))
        }
    }

    private fun metricOfExercise(db: TestDb, exerciseId: String): SeamMetric {
        val ex = db.queryOne("SELECT exerciseType FROM exercise WHERE id = ?", exerciseId)
        return if (ex?.get("exerciseType") == "cardio") SeamMetric.DURATION else SeamMetric.REPS
    }

    private fun rowToReferenceSet(row: Map<String, Any?>, metric: SeamMetric): ReferenceSessionSet {
        return ReferenceSessionSet(
            id = row["id"] as String,
            sessionId = row["sessionId"] as String,
            exerciseId = row["exerciseId"] as String,
            status = SetStatus.fromRaw(row["status"] as String),
            setClass = SetClass.fromRaw(row["setClass"] as String?),
            actualWeight = row["actualWeight"] as? Double ?: (row["actualWeight"] as? Number)?.toDouble(),
            actualReps = (row["actualReps"] as? Number)?.toInt(),
            actualDuration = (row["actualDuration"] as? Number)?.toInt(),
            completedAt = row["completedAt"] as String?,
            exerciseDefaultMetric = metric,
        )
    }

    private class ExerciseContext(
        val metric: SeamMetric,
        val history: List<ReferenceSessionSet>,
        val baselines: Map<PRKind, PersonalRecord>,
    )

    private fun loadExerciseContext(db: TestDb, exerciseId: String): ExerciseContext {
        val metric = metricOfExercise(db, exerciseId)
        val history = db.query(
            "SELECT * FROM completed_set WHERE exerciseId = ? AND deletedAt IS NULL", exerciseId)
            .map { rowToReferenceSet(it, metric) }
        val baselines = mutableMapOf<PRKind, PersonalRecord>()
        for (r in db.query("SELECT * FROM personal_record WHERE exerciseId = ? AND deletedAt IS NULL", exerciseId)) {
            val kind = PRKind.fromRaw(r["kind"] as String)
            // INV-PR2: one row per kind; first wins on duplicates.
            if (kind !in baselines) {
                baselines[kind] = PersonalRecord(
                    id = r["id"] as String,
                    exerciseId = r["exerciseId"] as String,
                    sessionId = r["sessionId"] as String,
                    setId = r["setId"] as String?,
                    kind = kind,
                    value = (r["value"] as Number).toDouble(),
                    achievedAt = r["achievedAt"] as String,
                    createdAt = r["createdAt"] as String,
                    updatedAt = r["updatedAt"] as String,
                    deletedAt = r["deletedAt"] as String?,
                )
            }
        }
        return ExerciseContext(metric, history, baselines)
    }

    /// Live path (PersonalRecordDAO.writeFromSet mirror).
    private fun writeFromSet(db: TestDb, setId: String): com.moore.records.PRWrite? {
        val setRow = db.queryOne(
            "SELECT * FROM completed_set WHERE id = ? AND deletedAt IS NULL", setId) ?: return null
        val ctx = loadExerciseContext(db, setRow["exerciseId"] as String)
        val set = rowToReferenceSet(setRow, ctx.metric)
        val write = PREngine.processNewSet(set, ctx.baselines) ?: return null
        for (kind in write.written) {
            val v = write.values[kind]!!
            val live = db.query(
                "SELECT * FROM personal_record WHERE exerciseId = ? AND kind = ? AND deletedAt IS NULL ORDER BY achievedAt DESC",
                set.exerciseId, kind.raw)
            if (live.isNotEmpty()) {
                db.update(
                    "UPDATE personal_record SET value = ?, setId = ?, sessionId = ?, achievedAt = ?, updatedAt = ? WHERE id = ?",
                    v, set.id, set.sessionId, set.completedAt ?: writeNow, writeNow, live[0]["id"])
                for (stale in live.drop(1)) {
                    db.update("UPDATE personal_record SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                        writeNow, writeNow, stale["id"])
                }
            } else {
                db.insert("personal_record", mapOf(
                    "id" to UUID.randomUUID().toString(),
                    "exerciseId" to set.exerciseId, "sessionId" to set.sessionId,
                    "setId" to set.id, "kind" to kind.raw, "value" to v,
                    "achievedAt" to (set.completedAt ?: writeNow),
                    "createdAt" to writeNow, "updatedAt" to writeNow))
            }
        }
        return write
    }

    /// Maintenance path (PersonalRecordDAO.rederive mirror).
    private fun rederiveExercise(db: TestDb, exerciseId: String) {
        val ctx = loadExerciseContext(db, exerciseId)
        val target = PREngine.rederive(ctx.history)
        for (kind in PRKind.allCases) {
            val existing = db.queryOne(
                "SELECT * FROM personal_record WHERE exerciseId = ? AND kind = ? AND deletedAt IS NULL",
                exerciseId, kind.raw)
            val t = target[kind]
            if (existing != null && t != null) {
                val existingValue = (existing["value"] as Number).toDouble()
                if (existingValue != t.value || existing["setId"] != t.setId) {
                    db.update(
                        "UPDATE personal_record SET value = ?, setId = ?, sessionId = ?, achievedAt = ?, updatedAt = ? WHERE id = ?",
                        t.value, t.setId, t.sessionId ?: (existing["sessionId"] as String),
                        t.achievedAt ?: (existing["achievedAt"] as String), writeNow, existing["id"])
                }
            } else if (existing == null && t != null) {
                db.insert("personal_record", mapOf(
                    "id" to UUID.randomUUID().toString(),
                    "exerciseId" to exerciseId, "sessionId" to (t.sessionId ?: ""),
                    "setId" to t.setId, "kind" to kind.raw, "value" to t.value,
                    "achievedAt" to (t.achievedAt ?: writeNow),
                    "createdAt" to writeNow, "updatedAt" to writeNow))
            } else if (existing != null && t == null) {
                db.update("UPDATE personal_record SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                    writeNow, writeNow, existing["id"])
            }
        }
    }

    private fun liveRows(db: TestDb, exerciseId: String): List<Map<String, Any?>> =
        db.query("SELECT * FROM personal_record WHERE exerciseId = ? AND deletedAt IS NULL ORDER BY kind", exerciseId)

    // MARK: - Runner

    @Test
    fun `schema - personal_record post-0009 canonical shape`() {
        val checks = Checks("Records.schema")
        TestDb().use { db ->
            db.applyAll(*MigrationChain.RECORDS_FULL)
            val cols = db.tableColumns("personal_record").map { it["name"] as String }
            for (c in listOf("id", "exerciseId", "sessionId", "setId", "kind", "value",
                "achievedAt", "createdAt", "updatedAt", "deletedAt")) {
                checks.ok(c in cols, "schema.personal_record.$c")
            }
            db.insert("exercise", mapOf("id" to "ex-x", "name" to "X", "exerciseType" to "strength",
                "isCustom" to 0, "createdAt" to "t", "updatedAt" to "t"))
            db.insert("workout_session", mapOf("id" to "s-x", "startedAt" to "t", "createdAt" to "t", "updatedAt" to "t"))
            db.insert("personal_record", mapOf("id" to "p-x", "exerciseId" to "ex-x", "sessionId" to "s-x",
                "kind" to "max_duration", "value" to 90.0, "achievedAt" to "t", "createdAt" to "t", "updatedAt" to "t"))
            val threw = try {
                db.insert("personal_record", mapOf("id" to "p-y", "exerciseId" to "ex-x", "sessionId" to "s-x",
                    "kind" to "weight", "value" to 1.0, "achievedAt" to "t", "createdAt" to "t", "updatedAt" to "t"))
                false
            } catch (e: Exception) {
                true
            }
            checks.ok(threw, "schema.legacy-kind-rejected: kind=weight must violate CHECK post-0009")
            val legacy = db.queryOne(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='personal_record__legacy_0001'")
            checks.ok(legacy != null, "schema.legacy-preserved: personal_record__legacy_0001 must survive")
            checks.flush()
        }
    }

    @Test
    fun `all PR fixtures pass on the ported engine + DAO harness`() {
        val checks = Checks("Records.fixtures")
        val files = listOf(
            "pr-write-happy-path.json",
            "first-touch-suppression.json",
            "failed-set-no-pr.json",
            "warmup-exclusion.json",
            "bodyweight-reps.json",
            "duration-exercise.json",
            "rederive-on-edit.json",
            "rederive-on-delete.json",
            "summary-escalation.json",
        )
        for (fname in files) {
            val fx = Fixtures.json("records", fname)
            val db = newDb()
            seedFixture(db, fx)

            for (vEl in fx["vectors"]!!.asJsonArray) {
                val v = vEl.obj
                val id = "$fname.${v["id"].strOrNull()}"

                // ---- insertSet ----
                val insertSet = v["insertSet"]?.obj
                if (insertSet != null) {
                    db.insert("completed_set", mapOf(
                        "id" to insertSet["id"].asString,
                        "sessionId" to insertSet["sessionId"].asString,
                        "exerciseId" to insertSet["exerciseId"].asString,
                        "sortOrder" to 1000,
                        "actualWeight" to insertSet["actualWeight"].numOrNull(),
                        "actualReps" to insertSet["actualReps"].intOrNull(),
                        "actualDuration" to insertSet["actualDuration"].intOrNull(),
                        "status" to insertSet["status"].asString,
                        "setClass" to insertSet["setClass"].strOrNull(),
                        "completedAt" to insertSet["completedAt"].strOrNull(),
                        "createdAt" to writeNow, "updatedAt" to writeNow))
                    checks.pass("$id.insert-set")
                }

                // ---- writeFromSet ----
                var lastWrite: com.moore.records.PRWrite? = null
                val writeEl = v["writeFromSet"]
                if (writeEl != null && !writeEl.isJsonNull) {
                    val calls = if (writeEl.isJsonArray) writeEl.asJsonArray.map { it.obj } else listOf(writeEl.obj)
                    for (c in calls) {
                        lastWrite = writeFromSet(db, c["setId"].asString)
                    }
                    val ex = v["expect"]?.obj
                    if (ex != null) {
                        if (ex.has("write") && ex["write"].isJsonNull) {
                            checks.eq(lastWrite, null, "$id.write-null")
                        } else if (ex.has("write")) {
                            checks.ok(lastWrite != null, "$id.write: expected write, got null")
                        }
                        val writtenExpected = ex["written"]?.takeIf { it.isJsonArray }?.asJsonArray?.map { it.asString }
                        if (writtenExpected != null) {
                            if (lastWrite == null) checks.fail("$id.written: expected write, got null")
                            else checks.sortedEq(lastWrite.written.map { it.raw }, writtenExpected, "$id.written")
                        }
                        val beatenExpected = ex["beaten"]?.takeIf { it.isJsonArray }?.asJsonArray?.map { it.asString }
                        if (beatenExpected != null) {
                            if (lastWrite == null) checks.fail("$id.beaten: expected write, got null")
                            else checks.sortedEq(lastWrite.beaten.map { it.raw }, beatenExpected, "$id.beaten")
                        }
                        if (ex.has("fired")) {
                            val firedExpect = ex["fired"]
                            if (firedExpect.isJsonNull) {
                                checks.ok(lastWrite?.fired == null, "$id.fired-null")
                            } else {
                                val f = firedExpect.obj
                                val fired = lastWrite?.fired
                                if (fired == null) {
                                    checks.fail("$id.fired: expected cue, got none")
                                } else {
                                    checks.eq(fired.headlineKind.raw, f["headlineKind"].asString, "$id.fired.headlineKind")
                                    checks.approx(fired.value, f["value"].asDouble, "$id.fired.value")
                                    checks.eq(fired.exerciseId, f["exerciseId"].asString, "$id.fired.exerciseId")
                                    checks.eq(fired.cueId, "cue.pr.achieved", "$id.fired.cueId")
                                    checks.eq(fired.hapticClass, "celebration", "$id.fired.hapticClass")
                                }
                            }
                        }
                    }
                }

                // ---- editSet / deleteSet / rederive ----
                val editSet = v["editSet"]?.obj
                if (editSet != null) {
                    db.update("UPDATE completed_set SET actualWeight = ?, actualReps = ?, updatedAt = ? WHERE id = ?",
                        editSet["actualWeight"].numOrNull(), editSet["actualReps"].intOrNull(),
                        writeNow, editSet["setId"].asString)
                    checks.pass("$id.edit-applied")
                }
                val deleteSet = v["deleteSet"]?.obj
                if (deleteSet != null) {
                    db.update("UPDATE completed_set SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                        writeNow, writeNow, deleteSet["setId"].asString)
                    checks.pass("$id.delete-applied")
                }
                val rederiveEl = v["rederive"]?.obj
                if (rederiveEl != null) {
                    rederiveExercise(db, rederiveEl["exerciseId"].asString)
                    checks.pass("$id.rederive-ran")
                }

                // ---- expect.rows ----
                val ex = v["expect"]?.obj
                val rowsExpect = ex?.get("rows")?.takeIf { it.isJsonArray }?.asJsonArray
                if (rowsExpect != null) {
                    // rows: [] asserts every seeded exercise has NO live PR rows.
                    if (rowsExpect.size() == 0) {
                        fx["seed"]?.obj?.get("exercises")?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { eEl ->
                            val eid = eEl.obj["id"].asString
                            checks.eq(liveRows(db, eid).size, 0, "$id.rows-empty.$eid")
                        }
                    }
                    // Per-kind live rows match exactly one row with right value/set/session.
                    val wantedKindsByExercise = mutableMapOf<String, MutableList<String>>()
                    for (wantEl in rowsExpect) {
                        val want = wantEl.obj
                        val exerciseId = want["exerciseId"].asString
                        val kind = want["kind"].asString
                        wantedKindsByExercise.getOrPut(exerciseId) { mutableListOf() }.add(kind)
                        val rows = db.query(
                            "SELECT * FROM personal_record WHERE exerciseId = ? AND kind = ? AND deletedAt IS NULL",
                            exerciseId, kind)
                        if (rows.size != 1) {
                            checks.fail("$id.row.$kind: expected exactly 1 live row, got ${rows.size}")
                            continue
                        }
                        val r = rows[0]
                        checks.approx((r["value"] as Number).toDouble(), want["value"].asDouble, "$id.row.$kind.value")
                        if (want.has("setId")) checks.eq(r["setId"], want["setId"].strOrNull(), "$id.row.$kind.setId")
                        if (want.has("sessionId")) checks.eq(r["sessionId"], want["sessionId"].strOrNull(), "$id.row.$kind.sessionId")
                        if (want.has("achievedAt")) checks.eq(r["achievedAt"], want["achievedAt"].strOrNull(), "$id.row.$kind.achievedAt")
                    }
                    // Kinds listed are the ONLY live kinds for the exercise(s) in scope.
                    for ((eid, wantedKinds) in wantedKindsByExercise) {
                        val liveKinds = liveRows(db, eid).map { it["kind"] as String }
                        checks.sortedEq(liveKinds, wantedKinds, "$id.rows.$eid.only-kinds")
                    }
                }

                // ---- summary ----
                val summary = v["summary"]?.obj
                if (summary != null) {
                    val rows = db.query("SELECT * FROM personal_record WHERE deletedAt IS NULL")
                        .filter { it["sessionId"] == summary["sessionId"].asString }
                        .sortedBy { PRKind.fromRaw(it["kind"] as String).precedenceRank }
                    val cards = summary["cards"].asJsonArray
                    checks.eq(rows.size, cards.size(), "$id.summary.count")
                    checks.eq(rows.size >= 2, summary["showBanner"].asBoolean, "$id.summary.banner")
                    rows.forEachIndexed { i, r ->
                        val want = if (i < cards.size()) cards[i].obj else null
                        if (want != null) {
                            checks.eq(r["exerciseId"], want["exerciseId"].strOrNull(), "$id.summary.card$i.exerciseId")
                            checks.eq(r["kind"], want["kind"].strOrNull(), "$id.summary.card$i.kind")
                            checks.approx((r["value"] as Number).toDouble(), want["value"].asDouble, "$id.summary.card$i.value")
                        }
                    }
                }
            }
            db.close()
        }
        checks.flush()
    }
}
