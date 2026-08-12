// SC-import@1.0.0 fixture runner (ticket #31 Stage A).
// Kotlin mirror of Tests/MooreImportTests/VerifyImport.mjs: the SAME CSV
// fixtures + JSON expectations run through the ported HevyCsvParser +
// HevyImportEngine; the apply harness mirrors HevyImportDAO.apply including
// SC-prs BR-009 PR re-derivation.
package com.moore.core

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.moore.foundation.SetStatus
import com.moore.hevyimport.HevyCsvError
import com.moore.hevyimport.HevyImportEngine
import com.moore.hevyimport.HevyImportError
import com.moore.hevyimport.ImportOptions
import com.moore.hevyimport.ImportPlan
import com.moore.hevyimport.LibraryRow
import com.moore.hevyimport.ExerciseRef
import com.moore.hevyimport.HevyUnit
import com.moore.records.PRKind
import com.moore.records.PREngine
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
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.util.UUID

class ImportFixtureTest {

    private val now = "2026-08-12T12:00:00Z"

    private val fixtureFiles = listOf(
        "01-hundred-sessions.json",
        "02-unit-detection.json",
        "03-exercise-matching.json",
        "04-grouping.json",
        "05-idempotent.json",
        "06-quarantine.json",
        "07-superset.json",
        "08-empty-rows.json",
        "09-mixed-units.json",
        "10-timezone.json",
        "11-rpe-distance.json",
        "12-preview-counts.json",
        "13-headers-edge.json",
        "14-notes-newlines.json",
    )

    // MARK: - DB plumbing

    private fun newDb(): TestDb {
        val db = TestDb()
        db.applyAll(*MigrationChain.ANALYTICS_FULL)
        return db
    }

    private fun seedLibrary(db: TestDb): Int {
        val seed = JsonParser.parseString(Fixtures.text("import", "builtin-library.json")).asJsonObject
        val exercises = seed["exercises"].asJsonArray
        for (exEl in exercises) {
            val ex = exEl.obj
            db.update("""
                INSERT OR IGNORE INTO exercise (id, name, exerciseType, equipmentSlug, isCustom, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, 0, ?, ?)
            """.trimIndent(),
                ex["id"].asString, ex["name"].asString,
                if (ex["defaultMetric"].asString == "duration") "cardio" else "strength",
                ex["equipment"].strOrNull(), now, now)
        }
        return exercises.size()
    }

    private fun libraryRows(db: TestDb): List<LibraryRow> {
        return db.query("SELECT id, name, equipmentSlug, isCustom FROM exercise WHERE deletedAt IS NULL").map {
            LibraryRow(
                id = it["id"] as String,
                name = it["name"] as String,
                nameNormalized = HevyImportEngine.normalize(it["name"] as String),
                equipmentSlug = it["equipmentSlug"] as String?,
                isCustom = (it["isCustom"] as Number).toInt() == 1,
            )
        }
    }

    private fun probeImportKeys(db: TestDb): Set<String> =
        db.query("SELECT importKey FROM workout_session WHERE deletedAt IS NULL AND importKey IS NOT NULL")
            .map { it["importKey"] as String }.toSet()

    /// 100-session generator (fixture 01; deterministic, no RNG) — ported from the .mjs.
    private fun generateHundredSessionsCsv(): String {
        val titles = listOf("Push Day", "Pull Day", "Leg Day", "Core Day", "Full Body")
        val exercises = listOf("Barbell Bench Press", "Squat (Barbell)", "Mystery Gizmo Lift")
        val months = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
        val lines = mutableListOf("title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps")
        for (i in 0 until 100) {
            // JS mirror: new Date(Date.UTC(2025, 0, 1 + i)) — day overflow rolls months.
            val d = java.time.LocalDate.of(2025, 1, 1).plusDays(i.toLong())
            val dateStr = "%02d ${months[d.monthValue - 1]} ${d.year}".format(d.dayOfMonth)
            val title = titles[i % 5]
            for (ex in exercises) {
                for (s in 0 until 3) {
                    val weight = 20 + ((i + s * 7) % 41) * 2.5
                    val reps = 5 + ((i + s) % 8)
                    lines.add("\"$title\",\"$dateStr, 08:00\",\"$dateStr, 08:55\",$ex,$s,normal,$weight,$reps")
                }
            }
        }
        return lines.joinToString("\n") + "\n"
    }

    // MARK: - apply harness (HevyImportDAO.apply mirror)

    private data class ImportSummary(
        var sessionsImported: Int = 0,
        var sessionsSkippedAlreadyImported: Int = 0,
        var setsImported: Int = 0,
        var exercisesCreated: Int = 0,
    )

    private fun applyPlan(db: TestDb, plan: ImportPlan): ImportSummary {
        val nowStamp = plan.now
        val summary = ImportSummary()
        val liveExercises = db.query("SELECT id, name, exerciseType, isCustom FROM exercise WHERE deletedAt IS NULL")
        val idByNormalized = HashMap<String, String>()
        val metricById = HashMap<String, String>()
        for (r in liveExercises) {
            idByNormalized[HevyImportEngine.normalize(r["name"] as String)] = r["id"] as String
            metricById[r["id"] as String] = if (r["exerciseType"] == "cardio") "duration" else "reps"
        }
        val idForNew = HashMap<String, String>()
        for (ne in plan.newExercises) {
            val existing = idByNormalized[ne.normalizedName]
            if (existing != null) {
                idForNew[ne.normalizedName] = existing
                continue
            }
            val id = UUID.randomUUID().toString()
            val exerciseType = if (ne.metric == "duration") "cardio" else "custom"   // INV-IM8
            db.insert("exercise", mapOf("id" to id, "name" to ne.name,
                "exerciseType" to exerciseType, "isCustom" to 1,
                "createdAt" to nowStamp, "updatedAt" to nowStamp))
            idByNormalized[ne.normalizedName] = id
            metricById[id] = ne.metric
            idForNew[ne.normalizedName] = id
            summary.exercisesCreated += 1
        }
        val affected = mutableListOf<String>()
        val affectedSeen = mutableSetOf<String>()
        for (session in plan.sessions) {
            if (session.alreadyImported) {
                summary.sessionsSkippedAlreadyImported += 1
                continue
            }
            val sessionId = UUID.randomUUID().toString()
            val changes = db.update("""
                INSERT OR IGNORE INTO workout_session
                  (id, name, notes, startedAt, endedAt, importSource, importKey, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, 'hevy', ?, ?, ?)
            """.trimIndent(), sessionId, session.name, session.notes, session.startedAt, session.endedAt,
                session.importKey, nowStamp, nowStamp)
            if (changes == 0) {
                summary.sessionsSkippedAlreadyImported += 1
                continue   // UNIQUE backstop
            }
            summary.sessionsImported += 1
            for (set in session.sets) {
                val exerciseId = when (val ref = set.exerciseRef) {
                    is ExerciseRef.Existing -> ref.id
                    is ExerciseRef.New -> idForNew[ref.normalizedName]
                        ?: error("unresolvedExercise: ${ref.normalizedName}")
                }
                db.insert("completed_set", mapOf(
                    "id" to UUID.randomUUID().toString(), "sessionId" to sessionId,
                    "exerciseId" to exerciseId, "sortOrder" to set.sortOrder,
                    "plannedWeight" to null, "plannedReps" to null, "plannedDuration" to null,
                    "actualWeight" to set.actualWeight, "actualReps" to set.actualReps,
                    "actualDuration" to set.actualDuration, "status" to "completed",
                    "completedAt" to set.completedAt, "createdAt" to nowStamp, "updatedAt" to nowStamp))
                summary.setsImported += 1
                if (exerciseId !in affectedSeen) {
                    affectedSeen.add(exerciseId)
                    affected.add(exerciseId)
                }
            }
        }
        for (exerciseId in affected) {
            rederiveExercisePRs(db, exerciseId, metricById[exerciseId] ?: "reps", nowStamp)
        }
        return summary
    }

    /// SC-prs@1.0.0 BR-009 re-derivation (as in VerifyImport.mjs / VerifyRecords.mjs).
    private fun rederiveExercisePRs(db: TestDb, exerciseId: String, metricRaw: String, nowStamp: String) {
        val metric = if (metricRaw == "duration") SeamMetric.DURATION else SeamMetric.REPS
        val history = db.query("""
            SELECT id, sessionId, status, setClass, actualWeight, actualReps, actualDuration, completedAt
            FROM completed_set WHERE exerciseId = ? AND deletedAt IS NULL
        """.trimIndent(), exerciseId).map {
            ReferenceSessionSet(
                id = it["id"] as String,
                sessionId = it["sessionId"] as String,
                exerciseId = exerciseId,
                status = SetStatus.fromRaw(it["status"] as String),
                setClass = com.moore.foundation.SetClass.fromRaw(it["setClass"] as String?),
                actualWeight = (it["actualWeight"] as? Number)?.toDouble(),
                actualReps = (it["actualReps"] as? Number)?.toInt(),
                actualDuration = (it["actualDuration"] as? Number)?.toInt(),
                completedAt = it["completedAt"] as String?,
                exerciseDefaultMetric = metric,
            )
        }
        val target = PREngine.rederive(history)
        for (kind in PRKind.allCases) {
            val existing = db.queryOne(
                "SELECT id, value, setId FROM personal_record WHERE exerciseId = ? AND kind = ? AND deletedAt IS NULL",
                exerciseId, kind.raw)
            val t = target[kind]
            if (existing != null && t != null) {
                val existingValue = (existing["value"] as Number).toDouble()
                if (existingValue != t.value || existing["setId"] != t.setId) {
                    db.update("""
                        UPDATE personal_record SET value = ?, setId = ?, sessionId = ?, achievedAt = ?, updatedAt = ?
                        WHERE id = ?
                    """.trimIndent(), t.value, t.setId, t.sessionId ?: "", t.achievedAt ?: nowStamp, nowStamp,
                        existing["id"])
                }
            } else if (existing == null && t != null) {
                db.insert("personal_record", mapOf(
                    "id" to UUID.randomUUID().toString(), "exerciseId" to exerciseId,
                    "sessionId" to (t.sessionId ?: ""), "setId" to t.setId, "kind" to kind.raw,
                    "value" to t.value, "achievedAt" to (t.achievedAt ?: nowStamp),
                    "createdAt" to nowStamp, "updatedAt" to nowStamp))
            } else if (existing != null && t == null) {
                db.update("UPDATE personal_record SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                    nowStamp, nowStamp, existing["id"])
            }
        }
    }

    // MARK: - Assertion walkers

    private fun assertCounts(checks: Checks, actual: com.moore.hevyimport.PreviewCounts, wanted: JsonObject, id: String) {
        for (k in wanted.keySet()) {
            if (k == "metadataDropped") {
                val md = wanted["metadataDropped"].obj
                for (mk in md.keySet()) {
                    val got = when (mk) {
                        "rpe" -> actual.metadataDropped.rpe
                        "exerciseNotes" -> actual.metadataDropped.exerciseNotes
                        "supersetId" -> actual.metadataDropped.supersetId
                        else -> error("unknown metadataDropped key $mk")
                    }
                    checks.eq(got, md[mk].asInt, "$id.counts.metadataDropped.$mk")
                }
            } else {
                val got = when (k) {
                    "dataRows" -> actual.dataRows
                    "emptyRowsSkipped" -> actual.emptyRowsSkipped
                    "duplicatesCollapsed" -> actual.duplicatesCollapsed
                    "sessionsFound" -> actual.sessionsFound
                    "setsImported" -> actual.setsImported
                    "exercisesMatched" -> actual.exercisesMatched
                    "sessionsAlreadyImported" -> actual.sessionsAlreadyImported
                    "cardioRowsSkipped" -> actual.cardioRowsSkipped
                    "foldedSetTypes" -> actual.foldedSetTypes
                    "quarantinedCount" -> actual.quarantinedCount
                    else -> error("unknown counts key $k")
                }
                checks.eq(got, wanted[k].asInt, "$id.counts.$k")
            }
        }
    }

    private fun assertPlanSessions(checks: Checks, actual: List<com.moore.hevyimport.ImportSessionPlan>,
                                   wanted: com.google.gson.JsonArray, id: String) {
        if (actual.size != wanted.size()) {
            checks.fail("$id.sessions.length: expected ${wanted.size()}, got ${actual.size}")
            return
        }
        wanted.forEachIndexed { i, wEl ->
            val w = wEl.obj
            val a = actual[i]
            for (k in w.keySet()) {
                when (k) {
                    "setCount" -> checks.eq(a.sets.size, w[k].asInt, "$id.sessions[$i].setCount")
                    "importKey" -> checks.eq(a.importKey, w[k].asString, "$id.sessions[$i].importKey")
                    "name" -> checks.eq(a.name, w[k].asString, "$id.sessions[$i].name")
                    "notes" -> checks.eq(a.notes, w[k].strOrNull(), "$id.sessions[$i].notes")
                    "startedAt" -> checks.eq(a.startedAt, w[k].asString, "$id.sessions[$i].startedAt")
                    "endedAt" -> checks.eq(a.endedAt, w[k].strOrNull(), "$id.sessions[$i].endedAt")
                    "alreadyImported" -> checks.eq(a.alreadyImported, w[k].asBoolean, "$id.sessions[$i].alreadyImported")
                    else -> error("unknown session field $k")
                }
            }
        }
    }

    private fun assertDb(checks: Checks, db: TestDb, want: JsonObject, id: String) {
        if (want.has("sessions")) checks.eq(
            (db.queryOne("SELECT COUNT(*) c FROM workout_session WHERE deletedAt IS NULL")?.get("c") as Number).toInt(),
            want["sessions"].asInt, "$id.db.sessions")
        if (want.has("sets")) checks.eq(
            (db.queryOne("SELECT COUNT(*) c FROM completed_set WHERE deletedAt IS NULL")?.get("c") as Number).toInt(),
            want["sets"].asInt, "$id.db.sets")
        if (want.has("customExercises")) checks.eq(
            (db.queryOne("SELECT COUNT(*) c FROM exercise WHERE isCustom = 1 AND deletedAt IS NULL")?.get("c") as Number).toInt(),
            want["customExercises"].asInt, "$id.db.customExercises")

        if (want["allSessionsImported"]?.asBoolean == true) {
            val bad = (db.queryOne(
                "SELECT COUNT(*) c FROM workout_session WHERE deletedAt IS NULL AND (importSource != 'hevy' OR importKey IS NULL OR name IS NULL)")
                ?.get("c") as Number).toInt()
            checks.eq(bad, 0, "$id.db.allSessionsImported")
        }
        if (want["allSetsImportedShape"]?.asBoolean == true) {
            val bad = (db.queryOne("""
                SELECT COUNT(*) c FROM completed_set WHERE deletedAt IS NULL AND (
                  status != 'completed' OR plannedWeight IS NOT NULL OR plannedReps IS NOT NULL
                  OR plannedDuration IS NOT NULL OR setClass IS NOT NULL OR completedAt IS NULL)
            """.trimIndent())?.get("c") as Number).toInt()
            checks.eq(bad, 0, "$id.db.allSetsImportedShape")
            // sortOrder contiguity per session (SC-foundation BR-005).
            val sessions = db.query("SELECT DISTINCT sessionId FROM completed_set WHERE deletedAt IS NULL")
            var contiguous = true
            for (s in sessions) {
                val orders = db.query(
                    "SELECT sortOrder FROM completed_set WHERE sessionId = ? AND deletedAt IS NULL ORDER BY sortOrder",
                    s["sessionId"]).map { (it["sortOrder"] as Number).toInt() }
                if (orders.withIndex().any { (i, o) -> o != i }) {
                    contiguous = false
                    break
                }
            }
            checks.eq(contiguous, true, "$id.db.sortOrderContiguous")
        }

        want["sessionRows"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEachIndexed { i, wEl ->
            val w = wEl.obj
            val row = db.queryOne("SELECT * FROM workout_session WHERE importKey = ? AND deletedAt IS NULL",
                w["importKey"].asString)
            if (row == null) {
                checks.fail("$id.db.sessionRows[$i]: no session for importKey ${w["importKey"].asString}")
                return@forEachIndexed
            }
            if (w.has("name")) checks.eq(row["name"], w["name"].strOrNull(), "$id.db.sessionRows[$i].name")
            if (w.has("notes")) checks.eq(row["notes"], w["notes"].strOrNull(), "$id.db.sessionRows[$i].notes")
            if (w.has("importSource")) checks.eq(row["importSource"], w["importSource"].strOrNull(), "$id.db.sessionRows[$i].importSource")
            if (w.has("startedAt")) checks.eq(row["startedAt"], w["startedAt"].strOrNull(), "$id.db.sessionRows[$i].startedAt")
            if (w.has("endedAt")) checks.eq(row["endedAt"], w["endedAt"].strOrNull(), "$id.db.sessionRows[$i].endedAt")
            if (w["routineIdNull"]?.asBoolean == true) checks.eq(row["routineId"], null, "$id.db.sessionRows[$i].routineIdNull")
        }

        want["setRows"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEachIndexed { i, wEl ->
            val w = wEl.obj
            val row = db.queryOne("""
                SELECT cs.*, e.name AS exerciseName FROM completed_set cs
                JOIN workout_session ws ON ws.id = cs.sessionId
                JOIN exercise e ON e.id = cs.exerciseId
                WHERE ws.importKey = ? AND cs.sortOrder = ? AND cs.deletedAt IS NULL
            """.trimIndent(), w["sessionImportKey"].asString, w["sortOrder"].asInt)
            if (row == null) {
                checks.fail("$id.db.setRows[$i]: no set for ${w["sessionImportKey"].asString} sortOrder ${w["sortOrder"].asInt}")
                return@forEachIndexed
            }
            if (w.has("exerciseName")) checks.eq(row["exerciseName"], w["exerciseName"].strOrNull(), "$id.db.setRows[$i].exerciseName")
            if (w.has("actualWeight")) {
                val expected = w["actualWeight"]
                if (expected.isJsonNull) checks.eq(row["actualWeight"], null, "$id.db.setRows[$i].actualWeight-null")
                else checks.approx((row["actualWeight"] as? Number)?.toDouble(), expected.asDouble, "$id.db.setRows[$i].actualWeight")
            }
            if (w.has("actualReps")) checks.eq((row["actualReps"] as? Number)?.toInt(), w["actualReps"].intOrNull(), "$id.db.setRows[$i].actualReps")
            if (w.has("actualDuration")) checks.eq((row["actualDuration"] as? Number)?.toInt(), w["actualDuration"].intOrNull(), "$id.db.setRows[$i].actualDuration")
            if (w.has("status")) checks.eq(row["status"], w["status"].strOrNull(), "$id.db.setRows[$i].status")
            if (w.has("completedAt")) checks.eq(row["completedAt"], w["completedAt"].strOrNull(), "$id.db.setRows[$i].completedAt")
            if (w["plannedNull"]?.asBoolean == true) {
                val allNull = row["plannedWeight"] == null && row["plannedReps"] == null && row["plannedDuration"] == null
                checks.eq(allNull, true, "$id.db.setRows[$i].plannedNull")
            }
        }

        want["exerciseRows"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEachIndexed { i, wEl ->
            val w = wEl.obj
            val row = db.queryOne("SELECT * FROM exercise WHERE name = ? AND deletedAt IS NULL", w["name"].asString)
            if (row == null) {
                checks.fail("$id.db.exerciseRows[$i]: no exercise named ${w["name"].asString}")
                return@forEachIndexed
            }
            if (w.has("exerciseType")) checks.eq(row["exerciseType"], w["exerciseType"].strOrNull(), "$id.db.exerciseRows[$i].exerciseType")
            if (w.has("isCustom")) checks.eq((row["isCustom"] as Number).toInt(), w["isCustom"].asInt, "$id.db.exerciseRows[$i].isCustom")
        }

        if (want.has("prKindsByExercise")) {
            val byEx = want["prKindsByExercise"].obj
            for (exerciseName in byEx.keySet()) {
                val ex = db.queryOne("SELECT id FROM exercise WHERE name = ? AND deletedAt IS NULL", exerciseName)
                if (ex == null) {
                    checks.fail("$id.db.prKinds: no exercise $exerciseName")
                    continue
                }
                val live = db.query(
                    "SELECT kind FROM personal_record WHERE exerciseId = ? AND deletedAt IS NULL ORDER BY kind",
                    ex["id"]).map { it["kind"] as String }
                val kinds = byEx[exerciseName].asJsonArray.map { it.asString }
                checks.sortedEq(live, kinds, "$id.db.prKinds.$exerciseName")
            }
        }

        want["prRows"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEachIndexed { i, wEl ->
            val w = wEl.obj
            val ex = db.queryOne("SELECT id FROM exercise WHERE name = ? AND deletedAt IS NULL", w["exerciseName"].asString)
            if (ex == null) {
                checks.fail("$id.db.prRows[$i]: no exercise ${w["exerciseName"].asString}")
                return@forEachIndexed
            }
            val rows = db.query(
                "SELECT * FROM personal_record WHERE exerciseId = ? AND kind = ? AND deletedAt IS NULL",
                ex["id"], w["kind"].asString)
            if (rows.size != 1) {
                checks.fail("$id.db.prRows[$i]: expected exactly 1 live row for ${w["exerciseName"].asString}/${w["kind"].asString}, got ${rows.size}")
                return@forEachIndexed
            }
            checks.approx((rows[0]["value"] as Number).toDouble(), w["value"].asDouble, "$id.db.prRows[$i].value")
            checks.ok(rows[0]["setId"] != null, "$id.db.prRows[$i].setId (must point at the holding set)")
            val sessionId = rows[0]["sessionId"] as? String
            checks.ok(sessionId != null && sessionId.isNotEmpty(), "$id.db.prRows[$i].sessionId (must point at the session)")
        }

        if (want.has("prLiveTotal")) checks.eq(
            (db.queryOne("SELECT COUNT(*) c FROM personal_record WHERE deletedAt IS NULL")?.get("c") as Number).toInt(),
            want["prLiveTotal"].asInt, "$id.db.prLiveTotal")
    }

    private fun dbSnapshot(db: TestDb): String {
        fun dump(table: String) = db.query("SELECT * FROM $table ORDER BY id").toString()
        return listOf(
            "workout_session=${dump("workout_session")}",
            "completed_set=${dump("completed_set")}",
            "exercise=${dump("exercise")}",
            "personal_record=${dump("personal_record")}",
        ).joinToString("|")
    }

    // MARK: - Runner

    @Test
    fun `schema - 0003 import columns and UNIQUE partial index`() {
        val checks = Checks("Import.schema")
        TestDb().use { db ->
            db.applyAll(*MigrationChain.ANALYTICS_FULL)
            val cols = db.tableColumns("workout_session").map { it["name"] as String }
            for (c in listOf("name", "notes", "importSource", "importKey", "routineId")) {
                checks.ok(c in cols, "schema.workout_session.$c")
            }
            db.insert("workout_session", mapOf("id" to "s-1", "startedAt" to "2025-01-01T00:00:00Z",
                "importSource" to "hevy", "importKey" to "k|2025-01-01T00:00:00Z", "createdAt" to "t", "updatedAt" to "t"))
            val ignored = db.update("""
                INSERT OR IGNORE INTO workout_session (id, startedAt, importSource, importKey, createdAt, updatedAt)
                VALUES ('s-2', '2025-01-01T00:00:00Z', 'hevy', 'k|2025-01-01T00:00:00Z', 't', 't')
            """.trimIndent()) == 0
            checks.ok(ignored, "schema.importKey-unique: duplicate importKey must be ignored")
            // NULL importKeys (hand-entered sessions) never collide — partial index scope.
            db.insert("workout_session", mapOf("id" to "s-3", "startedAt" to "2025-01-02T00:00:00Z",
                "createdAt" to "t", "updatedAt" to "t"))
            db.insert("workout_session", mapOf("id" to "s-4", "startedAt" to "2025-01-03T00:00:00Z",
                "createdAt" to "t", "updatedAt" to "t"))
            checks.pass("schema.import-columns.canonical")
        }
        checks.flush()
    }

    @Test
    fun `all import fixtures pass on the ported parser and engine`() {
        val checks = Checks("Import.fixtures")
        for (fname in fixtureFiles) {
            val fx = Fixtures.json("import", fname)

            for (vEl in fx["vectors"]!!.asJsonArray) {
                val v = vEl.obj
                val id = "$fname.${v["id"].asString}"
                val db = newDb()
                try {
                    seedLibrary(db)
                    fx["seed"]?.obj?.get("customExercises")?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { cEl ->
                        val c = cEl.obj
                        db.insert("exercise", mapOf("id" to c["id"].asString, "name" to c["name"].asString,
                            "exerciseType" to (c["exerciseType"].strOrNull() ?: "custom"), "isCustom" to 1,
                            "createdAt" to now, "updatedAt" to now))
                    }

                    val csvText = when {
                        v["generate"].strOrNull() == "hundredSessions" -> generateHundredSessionsCsv()
                        v.has("csv") && !v["csv"].isJsonNull -> v["csv"].asString
                        else -> Fixtures.text("import", v["csvFile"].asString)
                    }

                    val optionsObj = v["options"]?.obj
                    val unitOverrides = HashMap<String, HevyUnit>()
                    optionsObj?.get("unitOverrides")?.takeIf { it.isJsonObject }?.obj?.keySet()?.forEach { k ->
                        unitOverrides[k] = HevyUnit.fromRaw(optionsObj["unitOverrides"].obj[k].asString)!!
                    }
                    val options = ImportOptions(
                        targetUnit = HevyUnit.fromRaw(optionsObj?.get("targetUnit").strOrNull()) ?: HevyUnit.KG,
                        timezoneOffsetMinutes = optionsObj?.get("timezoneOffsetMinutes").intOrNull() ?: 0,
                        now = optionsObj?.get("now").strOrNull() ?: now,
                        unitOverrides = unitOverrides,
                        existingImportKeys = probeImportKeys(db),
                    )

                    var plan: ImportPlan? = null
                    var buildError: HevyImportError? = null
                    try {
                        plan = HevyImportEngine.buildPlan(csvText, libraryRows(db), options)
                    } catch (e: HevyImportError) {
                        buildError = e
                    } catch (e: HevyCsvError) {
                        buildError = HevyImportError.CsvMalformed(e.message ?: "")
                    }

                    val expectAbort = v["expectAbort"].strOrNull()
                    if (expectAbort != null) {
                        val code = when (buildError) {
                            is HevyImportError.NotHevyExport -> "notHevyExport"
                            is HevyImportError.CsvMalformed -> "csvMalformed"
                            null -> null
                        }
                        checks.eq(code, expectAbort, "$id.abort")
                        if (v.has("db")) assertDb(checks, db, v["db"].obj, id)   // nothing written on abort (INV-IM2)
                        continue
                    }
                    if (buildError != null) {
                        checks.fail("$id.build: unexpected error ${buildError.message}")
                        continue
                    }
                    val p = plan!!

                    val ex = v["expect"]?.obj ?: JsonObject()
                    if (ex.has("unit")) checks.eq(p.unit?.raw, ex["unit"].strOrNull(), "$id.unit")
                    if (ex.has("warnings")) checks.eq(p.warnings, ex["warnings"].asJsonArray.map { it.asString }, "$id.warnings")
                    if (ex.has("counts")) assertCounts(checks, p.counts, ex["counts"].obj, id)
                    if (ex.has("quarantined")) {
                        val expectedQ = ex["quarantined"].asJsonArray
                        checks.eq(p.quarantined.size, expectedQ.size(), "$id.quarantined.length")
                        expectedQ.forEachIndexed { qi, wEl ->
                            val w = wEl.obj
                            val a = p.quarantined.getOrNull(qi)
                            if (a == null) {
                                checks.fail("$id.quarantined[$qi] missing")
                                return@forEachIndexed
                            }
                            if (w.has("rowNumber")) checks.eq(a.rowNumber, w["rowNumber"].asInt, "$id.quarantined[$qi].rowNumber")
                            if (w.has("column")) checks.eq(a.column, w["column"].asString, "$id.quarantined[$qi].column")
                            if (w.has("value")) checks.eq(a.value, w["value"].asString, "$id.quarantined[$qi].value")
                            if (w.has("messageContains")) checks.eq(a.message.contains(w["messageContains"].asString), true,
                                "$id.quarantined[$qi].message")
                        }
                    }
                    if (ex.has("newExercises")) {
                        val got = p.newExercises.map {
                            mapOf("name" to it.name, "normalizedName" to it.normalizedName, "metric" to it.metric)
                        }
                        val want = ex["newExercises"].asJsonArray.map { el ->
                            val o = el.obj
                            mapOf("name" to o["name"].asString, "normalizedName" to o["normalizedName"].asString,
                                "metric" to o["metric"].asString)
                        }
                        checks.eq(got, want, "$id.newExercises")
                    }
                    if (ex.has("sessions")) assertPlanSessions(checks, p.sessions, ex["sessions"].asJsonArray, id)
                    if (ex.has("sessionsHead")) {
                        val head = ex["sessionsHead"].asJsonArray
                        assertPlanSessions(checks, p.sessions.take(head.size()), head, "$id.head")
                    }

                    // ---- apply (BR-015) ----
                    var summary: ImportSummary? = null
                    var applyError: Exception? = null
                    try {
                        summary = applyPlan(db, p)
                    } catch (e: Exception) {
                        applyError = e
                    }
                    if (applyError != null) {
                        checks.fail("$id.apply: ${applyError.message}")
                        continue
                    }
                    val sum = summary!!
                    if (ex.has("summary")) {
                        val s = ex["summary"].obj
                        for (k in s.keySet()) {
                            val got = when (k) {
                                "sessionsImported" -> sum.sessionsImported
                                "sessionsSkippedAlreadyImported" -> sum.sessionsSkippedAlreadyImported
                                "setsImported" -> sum.setsImported
                                "exercisesCreated" -> sum.exercisesCreated
                                else -> error("unknown summary key $k")
                            }
                            checks.eq(got, s[k].asInt, "$id.summary.$k")
                        }
                    }
                    if (ex.has("db")) assertDb(checks, db, ex["db"].obj, id)

                    // ---- re-import (BR-013 idempotency) ----
                    val reimport = v["reimport"]?.obj
                    if (reimport != null) {
                        val beforeReimport = dbSnapshot(db)
                        val options2 = options.copy(existingImportKeys = probeImportKeys(db))
                        val plan2 = HevyImportEngine.buildPlan(csvText, libraryRows(db), options2)
                        val rex = reimport["expect"]?.obj
                        if (rex != null && rex.has("counts")) assertCounts(checks, plan2.counts, rex["counts"].obj, "$id.reimport")
                        val summary2 = applyPlan(db, plan2)
                        if (rex != null && rex.has("summary")) {
                            val s = rex["summary"].obj
                            for (k in s.keySet()) {
                                val got = when (k) {
                                    "sessionsImported" -> summary2.sessionsImported
                                    "sessionsSkippedAlreadyImported" -> summary2.sessionsSkippedAlreadyImported
                                    "setsImported" -> summary2.setsImported
                                    "exercisesCreated" -> summary2.exercisesCreated
                                    else -> error("unknown summary key $k")
                                }
                                checks.eq(got, s[k].asInt, "$id.reimport.summary.$k")
                            }
                        }
                        if (reimport["dbUnchanged"]?.asBoolean == true) {
                            checks.eq(dbSnapshot(db), beforeReimport, "$id.reimport.dbUnchanged")
                        }
                    }
                } finally {
                    db.close()
                }
            }
        }
        checks.flush()
    }
}
