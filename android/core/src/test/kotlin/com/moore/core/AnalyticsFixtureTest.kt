// SC-analytics@1.0.0 fixture runner (ticket #31 Stage A).
// Kotlin mirror of Tests/MooreAnalyticsTests/VerifyAnalytics.mjs: the SAME
// fixtures seeded into a fresh in-memory DB, then derived read-only via the
// ported com.moore.analytics.AnalyticsEngine (INV-A1: analytics never writes).
package com.moore.core

import com.moore.analytics.AnalyticsEngine
import com.moore.analytics.AnalyticsSession
import com.moore.analytics.AnalyticsSet
import com.moore.analytics.ExerciseInfo
import com.moore.analytics.PRRow
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

class AnalyticsFixtureTest {

    private val seedNow = "2026-08-12T00:00:00Z"

    /// §6 UI copy used by the emptyState vectors (analytics surfaces the empty
    /// state, never a gate).
    private val copy = mapOf(
        "analytics.title" to "Analytics",
        "analytics.empty.trends" to "Log 3 sessions to see trends",
        "analytics.empty.history" to "No sessions yet",
        "analytics.empty.prs" to "No records yet",
        "history.title" to "History",
    )

    private fun newDb(): TestDb {
        val db = TestDb()
        db.applyAll(*MigrationChain.ANALYTICS_FULL)
        // Integration patch per Sources/MooreExercises/Migrations-DEPENDS-ON-19.md:
        // the one column AnalyticsDAO reads by name (0004 awaits its rewrite).
        db.exec("ALTER TABLE exercise ADD COLUMN category TEXT")
        return db
    }

    private fun seedFixture(db: TestDb, fx: com.google.gson.JsonObject) {
        val seed = fx["seed"]?.obj ?: return
        seed["exercises"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val e = el.obj
            db.insert("exercise", mapOf(
                "id" to e["id"].asString, "name" to e["name"].asString,
                "exerciseType" to (e["exerciseType"].strOrNull() ?: "strength"),
                "category" to e["category"].strOrNull(),
                "isCustom" to 0, "createdAt" to seedNow, "updatedAt" to seedNow,
                "deletedAt" to if (e["deleted"]?.asBoolean == true) seedNow else null))
        }
        seed["sessions"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val s = el.obj
            db.insert("workout_session", mapOf(
                "id" to s["id"].asString, "name" to s["name"].strOrNull(),
                "startedAt" to s["startedAt"].asString, "endedAt" to s["endedAt"].strOrNull(),
                "createdAt" to seedNow, "updatedAt" to seedNow,
                "deletedAt" to if (s["deleted"]?.asBoolean == true) seedNow else null))
        }
        val ordBySession = HashMap<String, Int>()
        seed["sets"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val s = el.obj
            val ord = ordBySession[s["sessionId"].asString] ?: 0
            ordBySession[s["sessionId"].asString] = ord + 1
            db.insert("completed_set", mapOf(
                "id" to s["id"].asString, "sessionId" to s["sessionId"].asString,
                "exerciseId" to s["exerciseId"].asString,
                "sortOrder" to (s["sortOrder"].intOrNull() ?: ord),
                "plannedWeight" to s["plannedWeight"].numOrNull(),
                "plannedReps" to s["plannedReps"].intOrNull(),
                "plannedDuration" to s["plannedDuration"].intOrNull(),
                "actualWeight" to s["actualWeight"].numOrNull(),
                "actualReps" to s["actualReps"].intOrNull(),
                "actualDuration" to s["actualDuration"].intOrNull(),
                "status" to s["status"].asString,
                "setClass" to s["setClass"].strOrNull(),
                "completedAt" to s["completedAt"].strOrNull(),
                "createdAt" to seedNow, "updatedAt" to seedNow,
                "deletedAt" to if (s["deleted"]?.asBoolean == true) seedNow else null))
        }
        seed["personalRecords"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val p = el.obj
            db.insert("personal_record", mapOf(
                "id" to UUID.randomUUID().toString(),
                "exerciseId" to p["exerciseId"].asString, "sessionId" to p["sessionId"].asString,
                "setId" to p["setId"].strOrNull(), "kind" to p["kind"].asString,
                "value" to p["value"].asDouble, "achievedAt" to p["achievedAt"].asString,
                "createdAt" to seedNow, "updatedAt" to seedNow,
                "deletedAt" to if (p["deleted"]?.asBoolean == true) seedNow else null))
        }
    }

    private fun loadSessions(db: TestDb) = db.query(
        "SELECT id, name, startedAt, endedAt FROM workout_session WHERE deletedAt IS NULL ORDER BY startedAt ASC")
        .map { AnalyticsSession(it["id"] as String, it["name"] as String?, it["startedAt"] as String, it["endedAt"] as String?) }

    private fun loadSets(db: TestDb) = db.query("""
        SELECT id, sessionId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration,
               actualWeight, actualReps, actualDuration, status, setClass, completedAt
        FROM completed_set WHERE deletedAt IS NULL ORDER BY sessionId, sortOrder ASC
    """.trimIndent()).map {
        AnalyticsSet(
            id = it["id"] as String, sessionId = it["sessionId"] as String,
            exerciseId = it["exerciseId"] as String, sortOrder = (it["sortOrder"] as Number).toInt(),
            plannedWeight = (it["plannedWeight"] as? Number)?.toDouble(),
            plannedReps = (it["plannedReps"] as? Number)?.toInt(),
            plannedDuration = (it["plannedDuration"] as? Number)?.toInt(),
            actualWeight = (it["actualWeight"] as? Number)?.toDouble(),
            actualReps = (it["actualReps"] as? Number)?.toInt(),
            actualDuration = (it["actualDuration"] as? Number)?.toInt(),
            status = it["status"] as String, setClass = it["setClass"] as String?,
            completedAt = it["completedAt"] as String?,
        )
    }

    private fun loadExercises(db: TestDb) = db.query("SELECT id, name, category FROM exercise ORDER BY id")
        .map { ExerciseInfo(it["id"] as String, it["name"] as String, it["category"] as String?) }

    private fun loadPRs(db: TestDb) = db.query(
        "SELECT id, exerciseId, sessionId, kind, value, achievedAt FROM personal_record WHERE deletedAt IS NULL ORDER BY achievedAt DESC")
        .map {
            PRRow(it["id"] as String, it["exerciseId"] as String, it["sessionId"] as String,
                it["kind"] as String, (it["value"] as Number).toDouble(), it["achievedAt"] as String)
        }

    // MARK: - Structured assertion mirrors

    private fun expectHeader(checks: Checks, actual: com.moore.analytics.AdherenceHeader,
                             want: com.google.gson.JsonObject, id: String) {
        checks.eq(actual.sessionsLast7, want["last7"].asInt, "$id.last7")
        checks.eq(actual.sessionsLast30, want["last30"].asInt, "$id.last30")
        checks.eq(actual.currentStreak, want["streak"].asInt, "$id.streak")
    }

    private fun expectPoints(checks: Checks, actual: List<com.moore.analytics.TrendPoint>,
                             want: com.google.gson.JsonArray, id: String) {
        if (actual.size != want.size()) {
            checks.fail("$id.points.length: expected ${want.size()}, got ${actual.size} — $actual")
            return
        }
        want.forEachIndexed { i, wEl ->
            val w = wEl.obj
            val a = actual[i]
            checks.eq(a.day, w["day"].asString, "$id.point$i.day")
            checks.approx(a.value, w["value"].asDouble, "$id.point$i.value", eps = 1e-6)
            checks.eq(a.segment, w["segment"].asInt, "$id.point$i.segment")
        }
    }

    private fun expectWeeks(checks: Checks, actual: List<com.moore.analytics.WeekTonnage>,
                            want: com.google.gson.JsonArray, id: String) {
        if (actual.size != want.size()) {
            checks.fail("$id.weeks.length: expected ${want.size()}, got ${actual.size} — $actual")
            return
        }
        want.forEachIndexed { i, wEl ->
            val w = wEl.obj
            checks.eq(actual[i].week, w["week"].asString, "$id.week$i.key")
            checks.approx(actual[i].tonnage, w["tonnage"].asDouble, "$id.week$i.tonnage", eps = 1e-6)
        }
    }

    private fun expectBuckets(checks: Checks, actual: List<com.moore.analytics.MuscleBucket>,
                              want: com.google.gson.JsonArray, id: String, tolerance: Double) {
        if (actual.size != want.size()) {
            checks.fail("$id.buckets.length: expected ${want.size()}, got ${actual.size} — $actual")
            return
        }
        want.forEachIndexed { i, wEl ->
            val w = wEl.obj
            checks.eq(actual[i].bucket, w["bucket"].asString, "$id.bucket$i.name")
            checks.approx(actual[i].tonnage, w["tonnage"].asDouble, "$id.bucket$i.tonnage", eps = 1e-6)
            checks.approx(actual[i].pct, w["pct"].asDouble, "$id.bucket$i.pct", eps = 1e-6)
        }
        val sum = actual.sumOf { it.pct }
        checks.ok(kotlin.math.abs(sum - 100) <= tolerance, "$id.buckets.sum-100±$tolerance ($sum)")
    }

    private fun expectItems(checks: Checks, actual: List<com.moore.analytics.PRListItem>,
                            want: com.google.gson.JsonArray, id: String) {
        if (actual.size != want.size()) {
            checks.fail("$id.items.length: expected ${want.size()}, got ${actual.size}")
            return
        }
        want.forEachIndexed { i, wEl ->
            val w = wEl.obj
            val a = actual[i]
            if (w.has("exerciseId")) checks.eq(a.exerciseId, w["exerciseId"].asString, "$id.item$i.exerciseId")
            if (w.has("exerciseName")) checks.eq(a.exerciseName, w["exerciseName"].asString, "$id.item$i.exerciseName")
            if (w.has("kind")) checks.eq(a.kind, w["kind"].asString, "$id.item$i.kind")
            if (w.has("value")) checks.approx(a.value, w["value"].asDouble, "$id.item$i.value", eps = 1e-6)
            if (w.has("day")) checks.eq(a.day, w["day"].asString, "$id.item$i.day")
            if (w.has("sessionId")) checks.eq(a.sessionId, w["sessionId"].asString, "$id.item$i.sessionId")
        }
    }

    private fun expectHistory(checks: Checks, actual: List<com.moore.analytics.HistoryMonth>,
                              want: com.google.gson.JsonArray, id: String) {
        if (actual.size != want.size()) {
            checks.fail("$id.months.length: expected ${want.size()}, got ${actual.size} — got ${actual.map { it.month }}")
            return
        }
        want.forEachIndexed { mi, wmEl ->
            val wm = wmEl.obj
            val am = actual[mi]
            checks.eq(am.month, wm["month"].asString, "$id.month$mi.key")
            val wrows = wm["rows"].asJsonArray
            if (am.rows.size != wrows.size()) {
                checks.fail("$id.month$mi.rows.length: expected ${wrows.size()}, got ${am.rows.size}")
                return@forEachIndexed
            }
            wrows.forEachIndexed { ri, wrEl ->
                val wr = wrEl.obj
                val ar = am.rows[ri]
                if (wr.has("sessionId")) checks.eq(ar.sessionId, wr["sessionId"].asString, "$id.month$mi.row$ri.sessionId")
                if (wr.has("day")) checks.eq(ar.day, wr["day"].asString, "$id.month$mi.row$ri.day")
                if (wr.has("name")) checks.eq(ar.name, wr["name"].strOrNull(), "$id.month$mi.row$ri.name")
                if (wr.has("completedCount")) checks.eq(ar.completedCount, wr["completedCount"].asInt, "$id.month$mi.row$ri.completedCount")
                if (wr.has("tonnage")) checks.approx(ar.tonnage, wr["tonnage"].asDouble, "$id.month$mi.row$ri.tonnage", eps = 1e-6)
                if (wr.has("prCount")) checks.eq(ar.prCount, wr["prCount"].asInt, "$id.month$mi.row$ri.prCount")
                if (wr.has("badge")) checks.eq(ar.prCount > 0, wr["badge"].asBoolean, "$id.month$mi.row$ri.badge(history.badge.pr)")
            }
        }
    }

    private fun expectDetailRows(checks: Checks, actual: List<com.moore.analytics.PlanActualRow>,
                                 want: com.google.gson.JsonArray, id: String) {
        if (actual.size != want.size()) {
            checks.fail("$id.rows.length: expected ${want.size()}, got ${actual.size}")
            return
        }
        want.forEachIndexed { i, wEl ->
            val w = wEl.obj
            val a = actual[i]
            fun actualValue(key: String): Any? = when (key) {
                "setId" -> a.setId
                "exerciseId" -> a.exerciseId
                "sortOrder" -> a.sortOrder
                "status" -> a.status
                "setClass" -> a.setClass
                "plannedWeight" -> a.plannedWeight
                "plannedReps" -> a.plannedReps
                "plannedDuration" -> a.plannedDuration
                "actualWeight" -> a.actualWeight
                "actualReps" -> a.actualReps
                "actualDuration" -> a.actualDuration
                else -> error("unknown detail row key $key")
            }
            for (k in w.keySet()) {
                val expected = Checks.toKotlin(w[k])
                val got = actualValue(k)
                if (expected is Number && got is Number) {
                    checks.approx(got.toDouble(), expected.toDouble(), "$id.row$i.$k", eps = 1e-6)
                } else {
                    checks.ok(Checks.looseEquals(got, expected), "$id.row$i.$k: expected $expected, got $got")
                }
            }
        }
    }

    // MARK: - Runner

    @Test
    fun `all analytics fixtures pass on the ported engine`() {
        val checks = Checks("Analytics.fixtures")
        val files = listOf(
            "01-zero-db.json",
            "02-three-sessions-two-exercises.json",
            "03-seven-day-gap-break.json",
            "04-tonnage-excludes-warmups.json",
            "05-muscle-split-sums.json",
            "06-streak-reset.json",
            "07-month-grouping.json",
            "08-plan-vs-actual.json",
            "09-pr-badges.json",
            "10-epley-math.json",
            "11-range-window.json",
        )
        for (fname in files) {
            val fx = Fixtures.json("analytics", fname)
            TestDb().use { db ->
                db.applyAll(*MigrationChain.ANALYTICS_FULL)
                db.exec("ALTER TABLE exercise ADD COLUMN category TEXT")
                seedFixture(db, fx)
                val sessions = loadSessions(db)
                val sets = loadSets(db)
                val exercises = loadExercises(db)
                val prs = loadPRs(db)
                val fixtureToday = fx["today"]?.strOrNull() ?: "2026-08-12"

                for (vEl in fx["vectors"]!!.asJsonArray) {
                    val v = vEl.obj
                    val id = "$fname.${v["id"].asString}"
                    val q = v["query"]?.obj ?: com.google.gson.JsonObject()
                    val today = q["today"].strOrNull() ?: v["today"].strOrNull() ?: fixtureToday
                    val rangeDays = q["rangeDays"]?.asInt ?: 30
                    val ex = v["expect"]?.obj ?: com.google.gson.JsonObject()

                    when (q["op"].strOrNull()) {
                        "header" -> expectHeader(checks,
                            AnalyticsEngine.adherenceHeader(sessions, sets, today), ex, id)
                        "qualifyingDays" -> {
                            val days = AnalyticsEngine.qualifyingDays(sessions, sets)
                            val want = ex["days"]?.takeIf { it.isJsonArray }?.asJsonArray?.map { it.asString } ?: emptyList()
                            checks.eq(days, want, "$id.qualifyingDays")
                        }
                        "trend" -> expectPoints(checks,
                            AnalyticsEngine.epleyTrend(sessions, sets, q["exerciseId"].asString, today, rangeDays,
                                q["gapBreakDays"]?.asInt ?: 7),
                            ex["points"]?.asJsonArray ?: com.google.gson.JsonArray(), id)
                        "tonnage" -> expectWeeks(checks,
                            AnalyticsEngine.weeklyTonnage(sessions, sets, today, rangeDays),
                            ex["weeks"]?.asJsonArray ?: com.google.gson.JsonArray(), id)
                        "split" -> expectBuckets(checks,
                            AnalyticsEngine.muscleSplit(sessions, sets, exercises, today, rangeDays),
                            ex["buckets"]?.asJsonArray ?: com.google.gson.JsonArray(), id,
                            ex["sumTolerance"]?.asDouble ?: 0.1)
                        "bucketMap" -> {
                            val map = ex["map"].obj
                            for (cat in map.keySet()) {
                                val input = if (cat == "NULL") null else cat
                                checks.eq(AnalyticsEngine.bucketForCategory(input), map[cat].asString, "$id.bucket($cat)")
                            }
                        }
                        "epley" -> checks.approx(
                            AnalyticsEngine.epley1RM(q["weight"].asDouble, q["reps"].asInt),
                            ex["value"].asDouble, id, eps = 1e-6)
                        "prList" -> expectItems(checks,
                            AnalyticsEngine.prList(prs, exercises),
                            ex["items"]?.asJsonArray ?: com.google.gson.JsonArray(), id)
                        "history" -> expectHistory(checks,
                            AnalyticsEngine.history(sessions, sets, prs),
                            ex["months"]?.asJsonArray ?: com.google.gson.JsonArray(), id)
                        "detail" -> {
                            val rows = AnalyticsEngine.sessionDetailRows(q["sessionId"].asString, sets)
                            expectDetailRows(checks, rows, ex["rows"]?.asJsonArray ?: com.google.gson.JsonArray(), id)
                            if (ex.has("sparkline")) {
                                val exerciseId = rows.firstOrNull()?.exerciseId ?: q["sparklineExerciseId"].strOrNull()!!
                                expectPoints(checks,
                                    AnalyticsEngine.epleyTrend(sessions, sets, exerciseId, today, 36500),
                                    ex["sparkline"].asJsonArray, "$id.sparkline")
                            }
                        }
                        "emptyState" -> {
                            // BR-008: everything renders empty; zero-data never gates the surface.
                            val header = AnalyticsEngine.adherenceHeader(sessions, sets, today)
                            checks.eq(header.sessionsLast7, 0, "$id.last7")
                            checks.eq(header.sessionsLast30, 0, "$id.last30")
                            checks.eq(header.currentStreak, 0, "$id.streak")
                            checks.eq(AnalyticsEngine.weeklyTonnage(sessions, sets, today, rangeDays).size, 0, "$id.tonnage-empty")
                            checks.eq(AnalyticsEngine.muscleSplit(sessions, sets, exercises, today, rangeDays).size, 0, "$id.split-empty")
                            checks.eq(AnalyticsEngine.prList(prs, exercises).size, 0, "$id.prlist-empty")
                            checks.eq(AnalyticsEngine.history(sessions, sets, prs).size, 0, "$id.history-empty")
                            for (e in exercises) {
                                checks.eq(AnalyticsEngine.epleyTrend(sessions, sets, e.id, today, rangeDays).size, 0,
                                    "$id.trend-empty.${e.id}")
                            }
                            val copyKey = ex["copyKey"].strOrNull() ?: "analytics.empty.trends"
                            checks.eq(copy[copyKey], ex["copy"].asString, "$id.copy($copyKey)")
                        }
                        else -> checks.fail("$id: unknown op ${q["op"].strOrNull()}")
                    }
                }
            }
        }
        checks.flush()
    }
}
