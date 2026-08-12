// SC-warmup@1.0.0 fixture runner (ticket #31 Stage A).
// Kotlin mirror of Tests/MooreWarmupTests/VerifyWarmup.mjs: fresh in-memory DB
// per fixture (migrations 0001,0002,0003,0005,0006,0007_progression_full,
// 0008_warmup); WarmupRamp.derive + the warmupApply materializer are the
// ported com.moore.warmup engine + the same SQL harness the .mjs uses.
package com.moore.core

import com.moore.progression.ExerciseMetric
import com.moore.progression.ProgressionEngine
import com.moore.progression.ProgressionRecord
import com.moore.progression.Scheme
import com.moore.foundation.SetStatus
import com.moore.warmup.WarmupRamp
import com.moore.test.Checks
import com.moore.test.Fixtures
import com.moore.test.MigrationChain
import com.moore.test.TestDb
import com.moore.test.numOrNull
import com.moore.test.obj
import com.moore.test.strOrNull
import org.junit.Test
import java.util.UUID

class WarmupFixtureTest {

    private val inventories = mapOf(
        "kg" to listOf(25.0, 20.0, 15.0, 10.0, 5.0, 2.5, 1.25),
        "lb" to listOf(45.0, 35.0, 25.0, 10.0, 5.0, 2.5),
    )

    private fun newDb(): TestDb {
        val db = TestDb()
        db.applyAll(*MigrationChain.WARMUP_FULL)
        return db
    }

    private fun nowIso() = java.time.Instant.now().toString()

    private fun insertExercise(db: TestDb, id: String) {
        db.insert("exercise", mapOf("id" to id, "name" to id, "exerciseType" to "strength",
            "isCustom" to 0, "createdAt" to nowIso(), "updatedAt" to nowIso()))
    }

    private fun insertRoutine(db: TestDb, id: String) {
        db.insert("routine", mapOf("id" to id, "name" to id, "sortOrder" to 0,
            "createdAt" to nowIso(), "updatedAt" to nowIso()))
    }

    private fun insertSession(db: TestDb, routineId: String?): String {
        val id = UUID.randomUUID().toString()
        db.insert("workout_session", mapOf("id" to id, "routineId" to routineId,
            "startedAt" to nowIso(), "createdAt" to nowIso(), "updatedAt" to nowIso()))
        return id
    }

    private fun insertWorkSet(db: TestDb, sessionId: String, exerciseId: String, sortOrder: Int,
                              weight: Double?, reps: Int?, setClass: String = "work") {
        db.insert("completed_set", mapOf(
            "id" to UUID.randomUUID().toString(), "sessionId" to sessionId, "exerciseId" to exerciseId,
            "sortOrder" to sortOrder, "plannedWeight" to weight, "plannedReps" to reps,
            "plannedDuration" to null, "actualWeight" to null, "actualReps" to null,
            "actualDuration" to null, "status" to "planned", "setClass" to setClass,
            "completedAt" to null, "createdAt" to nowIso(), "updatedAt" to nowIso(), "deletedAt" to null))
    }

    private fun upsertScheme(db: TestDb, routineId: String, exerciseId: String, warmupEnabled: Int) {
        db.insert("progression_scheme", mapOf(
            "id" to UUID.randomUUID().toString(), "routineId" to routineId, "exerciseId" to exerciseId,
            "scheme" to "none", "warmupEnabled" to warmupEnabled,
            "createdAt" to nowIso(), "updatedAt" to nowIso()))
    }

    private fun isEnabled(db: TestDb, routineId: String?, exerciseId: String): Boolean {
        if (routineId == null) return false
        val r = db.queryOne(
            "SELECT warmupEnabled FROM progression_scheme WHERE routineId = ? AND exerciseId = ? AND deletedAt IS NULL LIMIT 1",
            routineId, exerciseId)
        return ((r?.get("warmupEnabled") as? Number)?.toInt() ?: 0) == 1
    }

    /// Mirror of Sources/MooreWarmup/Materialize.swift (as in VerifyWarmup.mjs's warmupApply).
    private fun warmupApply(db: TestDb, sessionId: String, routineId: String?, barWeight: Double,
                            plateInventory: List<Double>) {
        if (routineId == null) return                                          // BR-002
        val slices = db.query("""
            SELECT exerciseId,
                   MIN(sortOrder) AS minSort,
                   MAX(CASE WHEN setClass IS NULL OR setClass = 'work' THEN plannedWeight END) AS W
            FROM completed_set
            WHERE sessionId = ? AND deletedAt IS NULL
            GROUP BY exerciseId
            ORDER BY MIN(sortOrder) ASC
        """.trimIndent(), sessionId)

        data class PlanEntry(val exerciseId: String, val insertBase: Int, val rows: List<com.moore.warmup.WarmupRow>)
        val plan = mutableListOf<PlanEntry>()
        var runningDelta = 0
        for (slice in slices) {
            val exerciseId = slice["exerciseId"] as String
            // BR-009: never regenerate — pair already ramped ⇒ skip.
            val already = (db.queryOne(
                "SELECT COUNT(*) AS n FROM completed_set WHERE sessionId = ? AND exerciseId = ? AND setClass = 'warmup' AND deletedAt IS NULL",
                sessionId, exerciseId)?.get("n") as Number).toInt() > 0
            if (already) continue
            if (!isEnabled(db, routineId, exerciseId)) continue
            val w = (slice["W"] as? Number)?.toDouble()
            val rows = WarmupRamp.derive(w, barWeight, plateInventory)
            if (rows.isEmpty()) continue
            plan.add(PlanEntry(exerciseId, (slice["minSort"] as Number).toInt(), rows))
            runningDelta += rows.size
        }
        if (plan.isEmpty()) return

        // Collision-free renumber: park all rows at +totalOffset, insert derived
        // rows into vacated originals, normalize to dense 0..n-1.
        val totalOffset = runningDelta
        db.update("UPDATE completed_set SET sortOrder = sortOrder + ? WHERE sessionId = ? AND deletedAt IS NULL",
            totalOffset, sessionId)

        val parked = plan.sortedBy { it.insertBase }
        var cumulative = 0
        for (entry in parked) {
            val position = entry.insertBase + totalOffset + cumulative
            val blockShift = entry.rows.size
            db.update("""
                UPDATE completed_set SET sortOrder = sortOrder + ?, updatedAt = ?
                WHERE sessionId = ? AND sortOrder >= ? AND deletedAt IS NULL
            """.trimIndent(), blockShift, nowIso(), sessionId, position)
            entry.rows.forEachIndexed { i, row ->
                db.insert("completed_set", mapOf(
                    "id" to UUID.randomUUID().toString(), "sessionId" to sessionId,
                    "exerciseId" to entry.exerciseId, "sortOrder" to position + i,
                    "plannedWeight" to row.weight, "plannedReps" to row.reps,
                    "plannedDuration" to null, "actualWeight" to null, "actualReps" to null,
                    "actualDuration" to null, "status" to "planned", "setClass" to "warmup",
                    "completedAt" to null, "createdAt" to nowIso(), "updatedAt" to nowIso(),
                    "deletedAt" to null))
            }
            cumulative += blockShift
        }

        val parkedRows = db.query(
            "SELECT id FROM completed_set WHERE sessionId = ? AND deletedAt IS NULL ORDER BY sortOrder ASC",
            sessionId)
        parkedRows.forEachIndexed { i, r ->
            db.update("UPDATE completed_set SET sortOrder = ? WHERE id = ?", i, r["id"])
        }
    }

    private fun planVsActual(db: TestDb, sessionId: String): List<List<Any?>> {
        return db.query("""
            SELECT exerciseId, COALESCE(setClass, 'work') AS cls, plannedWeight AS w, plannedReps AS r
            FROM completed_set WHERE sessionId = ? AND deletedAt IS NULL ORDER BY sortOrder ASC
        """.trimIndent(), sessionId).map { row ->
            listOf(row["exerciseId"], row["cls"], row["w"], row["r"])
        }
    }

    private fun expectSessionShape(checks: Checks, db: TestDb, sessionId: String,
                                   expectRows: com.google.gson.JsonArray, label: String) {
        val rows = planVsActual(db, sessionId)
        val first = expectRows.firstOrNull()?.asJsonArray
        val fourCols = first != null && first.size() >= 4
        val actual = rows.map { r -> if (fourCols) r else r.take(3) }
        val expected = expectRows.map { el ->
            el.asJsonArray.map { Checks.toKotlin(it) }
        }
        val match = actual.size == expected.size && actual.indices.all { i ->
            val a = actual[i]
            val e = expected[i]
            a.size == e.size && a.indices.all { j -> Checks.looseEquals(a[j], e[j]) }
        }
        checks.ok(match, "$label.session-shape ($actual)")
        // sortOrder contiguity (SC-foundation BR-005).
        val orders = db.query(
            "SELECT sortOrder FROM completed_set WHERE sessionId = ? AND deletedAt IS NULL ORDER BY sortOrder ASC",
            sessionId).map { (it["sortOrder"] as Number).toInt() }
        checks.ok(orders.withIndex().all { (i, v) -> v == i }, "$label.sortOrder-contiguous (BR-005)")
    }

    private fun workClassFilter(db: TestDb, sessionId: String, exerciseId: String): String {
        val hasWarmup = (db.queryOne("""
            SELECT COUNT(*) AS n FROM completed_set
            WHERE sessionId = ? AND exerciseId = ? AND setClass = 'warmup' AND deletedAt IS NULL
        """.trimIndent(), sessionId, exerciseId)?.get("n") as Number).toInt() > 0
        return if (hasWarmup) "setClass = 'work'" else "(setClass IS NULL OR setClass = 'work')"
    }

    // MARK: - Tests

    @Test
    fun `V1 pure ramp tables are byte-identical`() {
        val checks = Checks("Warmup.V1")
        val fx = Fixtures.json("warmup", "01-ramp-tables.json")
        for (vEl in fx["pureUnits"]!!.asJsonArray) {
            val v = vEl.obj
            val input = v["in"].obj
            val inv = inventories[input["unit"].asString]!!
            val w = input["w"].numOrNull()
            val bar = input["bar"].asDouble
            val got = WarmupRamp.derive(w, bar, inv).map { listOf<Any?>(it.weight, it.reps) }
            val expected = v["expect"].asJsonArray.map { el ->
                el.asJsonArray.map { Checks.toKotlin(it) }
            }
            val match = got.size == expected.size && got.indices.all { i ->
                got[i].size == expected[i].size &&
                    got[i].indices.all { j -> Checks.looseEquals(got[i][j], expected[i][j]) }
            }
            checks.ok(match, "01.${v["id"].asString} ramp=$got")
        }
        checks.flush()
    }

    @Test
    fun `V2 V6 gate and defaults`() {
        val checks = Checks("Warmup.V2V6")
        val fx = Fixtures.json("warmup", "02-gate-and-defaults.json")
        for (vEl in fx["materialize"]!!.asJsonArray) {
            val v = vEl.obj
            TestDb().use { db ->
                db.applyAll(*MigrationChain.WARMUP_FULL)
                val routineId = "rt-a"
                insertRoutine(db, routineId)
                val sessionId = insertSession(db, routineId)
                var order = 0
                for (exEl in v["exercises"].asJsonArray) {
                    val ex = exEl.obj
                    insertExercise(db, ex["id"].asString)
                    val scheme = v["scheme"]?.takeIf { !it.isJsonNull }?.obj
                    if (scheme != null) {
                        upsertScheme(db, routineId, ex["id"].asString, scheme["warmupEnabled"].asInt)
                    }
                    for (wEl in ex["work"].asJsonArray) {
                        val w = wEl.obj
                        insertWorkSet(db, sessionId, ex["id"].asString, order++,
                            w["weight"].numOrNull(), w["reps"].intOrNullSafe())
                    }
                }
                warmupApply(db, sessionId, routineId, 20.0, inventories["kg"]!!)
                expectSessionShape(checks, db, sessionId, v["expectSession"].asJsonArray, "02.${v["id"].asString}")
            }
        }
        checks.flush()
    }

    private fun com.google.gson.JsonElement?.intOrNullSafe(): Int? =
        if (this == null || isJsonNull) null else asInt

    @Test
    fun `V3 V4 V5 ticket vectors - session materialization shapes`() {
        val checks = Checks("Warmup.V3V4V5")
        for (file in listOf("03-two-rung-82.5.json", "04-three-rung-120.json", "05-collapse-bar-only.json")) {
            val fx = Fixtures.json("warmup", file)
            TestDb().use { db ->
                db.applyAll(*MigrationChain.WARMUP_FULL)
                val session = fx["session"].obj
                val routineId = session["routineId"].asString
                insertRoutine(db, routineId)
                val sessionId = insertSession(db, routineId)
                var order = 0
                for (exEl in session["exercises"].asJsonArray) {
                    val ex = exEl.obj
                    insertExercise(db, ex["id"].asString)
                    val scheme = session["scheme"].obj
                    upsertScheme(db, scheme["routineId"].asString, scheme["exerciseId"].asString,
                        scheme["warmupEnabled"].asInt)
                    for (wEl in ex["work"].asJsonArray) {
                        val w = wEl.obj
                        insertWorkSet(db, sessionId, ex["id"].asString, order++,
                            w["weight"].numOrNull(), w["reps"].intOrNullSafe())
                    }
                }
                warmupApply(db, sessionId, routineId, session["bar"].asDouble,
                    inventories[session["unit"].asString]!!)
                val id = file.split('-')[0]
                expectSessionShape(checks, db, sessionId, fx["expectSession"].asJsonArray, id)
                // Written-row shape (BR-008): warmup rows carry plannedX, NULL actuals, planned.
                val warmups = db.query("""
                    SELECT * FROM completed_set
                    WHERE sessionId = ? AND setClass = 'warmup' AND deletedAt IS NULL
                """.trimIndent(), sessionId)
                val shapeOk = warmups.isNotEmpty() && warmups.all { r ->
                    r["status"] == "planned" && r["actualWeight"] == null && r["actualReps"] == null &&
                        r["actualDuration"] == null && r["completedAt"] == null &&
                        r["plannedWeight"] != null && r["plannedReps"] != null
                }
                checks.ok(shapeOk, "$id.warmup-row-shape (BR-008; n=${warmups.size})")
            }
        }
        checks.flush()
    }

    @Test
    fun `V7 write shape and FSM behavior on written rows`() {
        val checks = Checks("Warmup.V7")
        val fx = Fixtures.json("warmup", "06-write-shape-and-fsm.json")
        TestDb().use { db ->
            db.applyAll(*MigrationChain.WARMUP_FULL)
            val s = fx["session"].obj
            val routineId = s["routineId"].asString
            insertRoutine(db, routineId)
            val sessionId = insertSession(db, routineId)
            var order = 0
            for (exEl in s["exercises"].asJsonArray) {
                val ex = exEl.obj
                insertExercise(db, ex["id"].asString)
                val scheme = s["scheme"].obj
                upsertScheme(db, scheme["routineId"].asString, scheme["exerciseId"].asString,
                    scheme["warmupEnabled"].asInt)
                for (wEl in ex["work"].asJsonArray) {
                    val w = wEl.obj
                    insertWorkSet(db, sessionId, ex["id"].asString, order++,
                        w["weight"].numOrNull(), w["reps"].intOrNullSafe())
                }
            }
            warmupApply(db, sessionId, routineId, s["bar"].asDouble, inventories[s["unit"].asString]!!)

            val warmupRows = db.query("""
                SELECT * FROM completed_set
                WHERE sessionId = ? AND setClass = 'warmup' AND deletedAt IS NULL ORDER BY sortOrder
            """.trimIndent(), sessionId)
            val sh = fx["expectRowShape"].obj
            val shapeOk = warmupRows.all { r ->
                r["setClass"] == sh["setClass"].asString && r["status"] == sh["status"].asString &&
                    Checks.looseEquals(r["actualWeight"], Checks.toKotlin(sh["actualWeight"])) &&
                    Checks.looseEquals(r["actualReps"], Checks.toKotlin(sh["actualReps"])) &&
                    Checks.looseEquals(r["actualDuration"], Checks.toKotlin(sh["actualDuration"])) &&
                    Checks.looseEquals(r["completedAt"], Checks.toKotlin(sh["completedAt"]))
            }
            checks.ok(shapeOk, "07.row-shape (BR-008)")
            checks.ok(sh["uiChip"].asString == "WU" && sh["uiGrayed"].asBoolean,
                "07.ui-chip-contract (BR-016: WU chip + grayed — renderer input)")

            for (stepEl in fx["fsm"].asJsonArray) {
                val step = stepEl.obj
                val row = warmupRows[step["index"].asInt]
                when (step["action"].asString) {
                    "accept" -> {
                        // SC-workout-logging BR-001 1-tap: actualX = plannedX, status completed.
                        db.update("""
                            UPDATE completed_set SET status='completed', actualWeight=plannedWeight,
                                actualReps=plannedReps, completedAt=?, updatedAt=? WHERE id=?
                        """.trimIndent(), nowIso(), nowIso(), row["id"])
                        val r = db.queryOne("SELECT * FROM completed_set WHERE id=?", row["id"])!!
                        checks.eq(r["status"], step["expectStatus"].asString, "07.${step["id"].asString}.status")
                        val expectActuals = step["expectActuals"].obj
                        val weightOk = Checks.looseEquals(r["actualWeight"], Checks.toKotlin(expectActuals["actualWeight"]))
                        val repsOk = Checks.looseEquals(r["actualReps"], Checks.toKotlin(expectActuals["actualReps"]))
                        checks.ok(weightOk && repsOk, "07.${step["id"].asString}.one-tap-copies-planned (BR-017/BR-018)")
                    }
                    "drop" -> {
                        db.update("UPDATE completed_set SET status='dropped', updatedAt=? WHERE id=?",
                            nowIso(), row["id"])
                        val r = db.queryOne("SELECT status FROM completed_set WHERE id=?", row["id"])!!
                        checks.eq(r["status"], step["expectStatus"].asString,
                            "07.${step["id"].asString}.status (BR-018 drop path)")
                    }
                }
            }
        }
        checks.flush()
    }

    @Test
    fun `V8 V9 PR exclusion and volume exclusion`() {
        val checks = Checks("Warmup.V8V9")
        val fx = Fixtures.json("warmup", "07-pr-and-volume.json")
        TestDb().use { db ->
            db.applyAll(*MigrationChain.WARMUP_FULL)
            val s = fx["session"].obj
            val routineId = s["routineId"].asString
            insertRoutine(db, routineId)
            val sessionId = insertSession(db, routineId)
            var order = 0
            for (exEl in s["exercises"].asJsonArray) {
                val ex = exEl.obj
                insertExercise(db, ex["id"].asString)
                val scheme = s["scheme"].obj
                upsertScheme(db, scheme["routineId"].asString, scheme["exerciseId"].asString,
                    scheme["warmupEnabled"].asInt)
                for (wEl in ex["work"].asJsonArray) {
                    val w = wEl.obj
                    insertWorkSet(db, sessionId, ex["id"].asString, order++,
                        w["weight"].numOrNull(), w["reps"].intOrNullSafe())
                }
            }
            warmupApply(db, sessionId, routineId, s["bar"].asDouble, inventories[s["unit"].asString]!!)

            for (prEl in fx["preExistingPRs"]?.asJsonArray ?: com.google.gson.JsonArray()) {
                val pr = prEl.obj
                db.insert("personal_record", mapOf(
                    "id" to UUID.randomUUID().toString(), "exerciseId" to pr["exerciseId"].asString,
                    "setId" to null, "kind" to pr["kind"].asString, "value" to pr["value"].asDouble,
                    "achievedAt" to nowIso(), "createdAt" to nowIso(), "updatedAt" to nowIso()))
            }

            if (s["completeAllAtPlanned"]?.asBoolean == true) {
                db.update("""
                    UPDATE completed_set SET status='completed', actualWeight=plannedWeight,
                        actualReps=plannedReps, completedAt=?, updatedAt=?
                    WHERE sessionId=? AND deletedAt IS NULL
                """.trimIndent(), nowIso(), nowIso(), sessionId)
            }

            // BR-013: PR derivation reads work-class rows only (BR-015 filter).
            val workFilter = workClassFilter(db, sessionId, "ex-bench")
            val workRows = db.query("""
                SELECT * FROM completed_set
                WHERE sessionId=? AND exerciseId='ex-bench' AND $workFilter
                  AND status='completed' AND deletedAt IS NULL
            """.trimIndent(), sessionId)
            checks.ok(workRows.isNotEmpty(), "07.harness.completed-work-rows-present")
            val candidates = mapOf(
                "max_1rm" to workRows.maxOf { ((it["actualWeight"] as? Number)?.toDouble() ?: 0.0) },
                "max_volume" to workRows.maxOf {
                    ((it["actualWeight"] as? Number)?.toDouble() ?: 0.0) *
                        ((it["actualReps"] as? Number)?.toInt() ?: 0).toDouble()
                },
                "max_reps" to workRows.maxOf { ((it["actualReps"] as? Number)?.toInt() ?: 0).toDouble() },
                "max_duration" to workRows.maxOf { ((it["actualDuration"] as? Number)?.toInt() ?: 0).toDouble() },
            )
            checks.eq(candidates["max_reps"], 5.0, "07.v8.work-feed-max-reps (warm-up 10 excluded)")
            checks.eq(candidates["max_1rm"], 82.5, "07.v8.work-feed-max-1rm")
            val repPr = db.queryOne(
                "SELECT value FROM personal_record WHERE exerciseId='ex-bench' AND kind='rep'")
            checks.eq((repPr?.get("value") as? Number)?.toDouble(), 8.0, "07.v8.rep-pr-still-8 (bar×10 never writes max_reps)")
            val prWithWarmupSet = (db.queryOne("""
                SELECT COUNT(*) AS n FROM personal_record pr
                JOIN completed_set cs ON cs.id = pr.setId
                WHERE cs.setClass = 'warmup'
            """.trimIndent())?.get("n") as Number).toInt()
            checks.eq(prWithWarmupSet, 0, "07.v8.no-pr-references-warmup-set (BR-013)")

            // BR-014: tonnage excludes warm-up rows.
            val all = (db.queryOne("""
                SELECT SUM(actualWeight*actualReps) AS v FROM completed_set
                WHERE sessionId=? AND status='completed' AND deletedAt IS NULL
            """.trimIndent(), sessionId)?.get("v") as? Number)?.toDouble() ?: 0.0
            val work = (db.queryOne("""
                SELECT SUM(actualWeight*actualReps) AS v FROM completed_set
                WHERE sessionId=? AND status='completed' AND deletedAt IS NULL AND (setClass IS NULL OR setClass='work')
            """.trimIndent(), sessionId)?.get("v") as? Number)?.toDouble() ?: 0.0
            val expect = fx["expect"].obj
            checks.approx(work, expect["workOnlyVolume"].asDouble, "07.v9.work-volume")
            checks.approx(all, expect["allRowsVolume"].asDouble, "07.v9.all-rows-volume")
            checks.approx(all - work, expect["allRowsVolume"].asDouble - expect["workOnlyVolume"].asDouble,
                "07.v9.warmup-excluded-delta (BR-014)")
        }
        checks.flush()
    }

    @Test
    fun `V10 V11 stall immunity clean predicate and immutability`() {
        val checks = Checks("Warmup.V10V11")
        val fx = Fixtures.json("warmup", "08-stall-clean-immutable.json")
        for (vEl in fx["stall"].asJsonArray) {
            val v = vEl.obj
            TestDb().use { db ->
                db.applyAll(*MigrationChain.WARMUP_FULL)
                insertExercise(db, "ex-bench")
                val sessionId = insertSession(db, null)
                v["session"].asJsonArray.forEachIndexed { i, sEl ->
                    val st = sEl.obj
                    db.insert("completed_set", mapOf(
                        "id" to UUID.randomUUID().toString(), "sessionId" to sessionId,
                        "exerciseId" to st["exerciseId"].asString, "sortOrder" to i,
                        "plannedWeight" to st["plannedWeight"].numOrNull(),
                        "plannedReps" to st["plannedReps"].intOrNullSafe(),
                        "plannedDuration" to null,
                        "actualWeight" to st["actualWeight"].numOrNull(),
                        "actualReps" to st["actualReps"].intOrNullSafe(),
                        "actualDuration" to null,
                        "status" to st["status"].asString, "setClass" to st["setClass"].strOrNull(),
                        "completedAt" to nowIso(), "createdAt" to nowIso(), "updatedAt" to nowIso(),
                        "deletedAt" to null))
                }
                val workFilter = workClassFilter(db, sessionId, "ex-bench")
                val workRows = db.query("""
                    SELECT * FROM completed_set
                    WHERE sessionId=? AND exerciseId='ex-bench' AND $workFilter AND deletedAt IS NULL
                    ORDER BY sortOrder ASC
                """.trimIndent(), sessionId)

                // Clean predicate over work rows (ProgressionEngine.clean, reps metric).
                val refSets = workRows.mapIndexed { i, r ->
                    com.moore.progression.ReferenceSessionSet(
                        sessionId = r["sessionId"] as String,
                        status = SetStatus.fromRaw(r["status"] as String),
                        exerciseId = r["exerciseId"] as String,
                        setOrdinal = i,
                        plannedWeight = (r["plannedWeight"] as? Number)?.toDouble(),
                        plannedReps = (r["plannedReps"] as? Number)?.toInt(),
                        actualWeight = (r["actualWeight"] as? Number)?.toDouble(),
                        actualReps = (r["actualReps"] as? Number)?.toInt(),
                    )
                }
                val clean = ProgressionEngine.clean(refSets, ExerciseMetric.REPS)
                val expect = v["expect"].obj
                checks.eq(clean, expect["clean"].asBoolean, "08.${v["id"].asString}.clean (BR-012/BR-011)")

                var rec = ProgressionRecord(
                    id = "r", routineId = "rt", exerciseId = "ex-bench", scheme = Scheme.NONE,
                    stallCount = v["stallCountBefore"].asInt, stallMuted = false, nextBannerAt = 3,
                )
                val repeats = v["repeat"]?.asInt ?: 1
                var bannerSeen = false
                val previousWeight = v["previousWeight"].numOrNull()
                repeat(repeats) {
                    val r = ProgressionEngine.onSessionFinished(
                        record = rec,
                        currentSessionSets = refSets,
                        previousWorkingWeight = previousWeight,
                        metric = ExerciseMetric.REPS,
                        exerciseName = "EX",
                    )
                    rec = r.updatedRecord
                    bannerSeen = bannerSeen || r.shouldBanner
                }
                checks.eq(rec.stallCount, expect["stallCountAfter"].asInt, "08.${v["id"].asString}.stallCount (BR-011)")
                checks.eq(bannerSeen, expect["banner"].asBoolean, "08.${v["id"].asString}.banner")
            }
        }

        // BR-009 double-apply is a no-op.
        val da = fx["doubleApply"].obj["session"].obj
        TestDb().use { db ->
            db.applyAll(*MigrationChain.WARMUP_FULL)
            val routineId = da["routineId"].asString
            insertRoutine(db, routineId)
            val sessionId = insertSession(db, routineId)
            var order = 0
            for (exEl in da["exercises"].asJsonArray) {
                val ex = exEl.obj
                insertExercise(db, ex["id"].asString)
                val scheme = da["scheme"].obj
                upsertScheme(db, scheme["routineId"].asString, scheme["exerciseId"].asString,
                    scheme["warmupEnabled"].asInt)
                for (wEl in ex["work"].asJsonArray) {
                    val w = wEl.obj
                    insertWorkSet(db, sessionId, ex["id"].asString, order++,
                        w["weight"].numOrNull(), w["reps"].intOrNullSafe())
                }
            }
            warmupApply(db, sessionId, routineId, da["bar"].asDouble, inventories[da["unit"].asString]!!)
            val after1 = (db.queryOne(
                "SELECT COUNT(*) AS n FROM completed_set WHERE sessionId=? AND deletedAt IS NULL", sessionId)
                ?.get("n") as Number).toInt()
            warmupApply(db, sessionId, routineId, da["bar"].asDouble, inventories[da["unit"].asString]!!)
            val after2 = (db.queryOne(
                "SELECT COUNT(*) AS n FROM completed_set WHERE sessionId=? AND deletedAt IS NULL", sessionId)
                ?.get("n") as Number).toInt()
            val expected = fx["doubleApply"].obj["expectRowCountAfterSecondApply"].asInt
            checks.ok(after2 == expected && after1 == after2,
                "08.v11.double-apply-noop (BR-009; $after1->$after2)")
        }
        checks.flush()
    }

    @Test
    fun `V12 interleave renumber`() {
        val checks = Checks("Warmup.V12")
        val fx = Fixtures.json("warmup", "09-interleave-renumber.json")
        TestDb().use { db ->
            db.applyAll(*MigrationChain.WARMUP_FULL)
            val s = fx["session"].obj
            val blueprintSets = s["blueprintSets"].asJsonArray
            val exerciseIds = blueprintSets.map { it.obj["exerciseId"].asString }.distinct()
            exerciseIds.forEach { insertExercise(db, it) }
            val routineId = s["routineId"].asString
            insertRoutine(db, routineId)
            val sessionId = insertSession(db, routineId)
            for (scEl in s["schemes"].asJsonArray) {
                val sc = scEl.obj
                upsertScheme(db, sc["routineId"].asString, sc["exerciseId"].asString, sc["warmupEnabled"].asInt)
            }
            blueprintSets.forEachIndexed { i, xEl ->
                val x = xEl.obj
                insertWorkSet(db, sessionId, x["exerciseId"].asString, i,
                    x["weight"].numOrNull(), x["reps"].intOrNullSafe())
            }
            warmupApply(db, sessionId, routineId, s["bar"].asDouble, inventories[s["unit"].asString]!!)
            expectSessionShape(checks, db, sessionId, fx["expectSession"].asJsonArray,
                "09.v12-interleave-renumber")
        }
        checks.flush()
    }

    @Test
    fun `migration 0008 scaffold checks`() {
        val checks = Checks("Warmup.migration0008")
        TestDb().use { db ->
            db.applyAll(*MigrationChain.WARMUP_FULL)
            val t = db.queryOne(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='warmup_contract_scaffold'")
            checks.ok(t != null, "migration.0008.scaffold-table-exists")
            val marker = db.queryOne(
                "SELECT * FROM warmup_contract_scaffold WHERE id='sc-warmup-1.0.0-shape-check'")
            checks.ok(marker != null, "migration.0008.shape-assertion-marker (setClass+warmupEnabled confirmed present)")
            val cols = db.tableColumns("progression_scheme").map { it["name"] as String }
            checks.ok("warmupEnabled" in cols, "migration.0008.warmupEnabled-present (BR-010 default OFF)")
        }
        checks.flush()
    }
}
