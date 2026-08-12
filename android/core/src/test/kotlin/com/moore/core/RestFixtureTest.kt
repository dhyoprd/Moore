// SC-rest@1.0.0 fixture runner (ticket #31 Stage A).
// Kotlin mirror of Tests/MooreRestTests/VerifyRest.mjs: the SAME fixtures run
// through the ported com.moore.rest.RestCycle + RestResolver; the persistence
// vector exercises migration-0007's app_setting rows (INV-S2 re-seed probe).
package com.moore.core

import com.moore.rest.RestAction
import com.moore.rest.RestCycle
import com.moore.rest.RestCueEvent
import com.moore.rest.RestResolution
import com.moore.rest.RestResolver
import com.moore.rest.RestSettings
import com.moore.rest.RestSource
import com.moore.test.Checks
import com.moore.test.Fixtures
import com.moore.test.MigrationChain
import com.moore.test.TestDb
import com.moore.test.intOrNull
import com.moore.test.numOrNull
import com.moore.test.obj
import com.moore.test.strOrNull
import org.junit.Test

class RestFixtureTest {

    private val settingsSeedSql = """
        INSERT OR IGNORE INTO app_setting (key, value, updatedAt) VALUES
          ('defaultRestCompoundSec',  '180', strftime('%Y-%m-%dT%H:%M:%fZ','now')),
          ('defaultRestIsolationSec', '90',  strftime('%Y-%m-%dT%H:%M:%fZ','now'));
    """.trimIndent()

    private fun freshDb(): TestDb {
        val db = TestDb()
        db.applyAll(*(MigrationChain.FOUNDATION + MigrationChain.ROUTINES + MigrationChain.REST))
        return db
    }

    // MARK: - Persistence helpers (seam-2 mirror)

    private fun fetchSettings(db: TestDb): Map<String, Int> {
        fun value(key: String): String? =
            db.queryOne("SELECT value FROM app_setting WHERE key = ?", key)?.get("value") as String?
        return mapOf(
            "defaultRestCompoundSec" to (value("defaultRestCompoundSec")?.toIntOrNull() ?: 180),
            "defaultRestIsolationSec" to (value("defaultRestIsolationSec")?.toIntOrNull() ?: 90),
        )
    }

    private fun updateSettings(db: TestDb, compoundSec: Int?, isolationSec: Int?, at: String) {
        fun upsert(key: String, v: Int) {
            db.update("""
                INSERT INTO app_setting (key, value, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
            """.trimIndent(), key, v.toString(), at)
        }
        if (compoundSec != null) upsert("defaultRestCompoundSec", compoundSec)
        if (isolationSec != null) upsert("defaultRestIsolationSec", isolationSec)
    }

    private fun snapshotTable(db: TestDb, table: String): String =
        db.query("SELECT * FROM $table ORDER BY rowid").toString()

    // MARK: - FSM step executor

    private fun runFsmSteps(checks: Checks, fixture: com.google.gson.JsonObject,
                            vector: com.google.gson.JsonObject, db: TestDb?) {
        val cycle = RestCycle()
        val defaultsObj = vector["settingsDefaults"]?.obj ?: fixture["settingsDefaults"]?.obj
        val settingsDefaults = RestSettings(
            defaultRestCompoundSec = defaultsObj?.get("defaultRestCompoundSec").intOrNull() ?: 180,
            defaultRestIsolationSec = defaultsObj?.get("defaultRestIsolationSec").intOrNull() ?: 90,
        )
        val cues = mutableListOf<String>()
        val snapshotTable = fixture["database"]?.obj?.get("snapshotTable")?.strOrNull()
        val before = if (snapshotTable != null && db != null) snapshotTable(db, snapshotTable) else null

        for ((i, stepEl) in vector["steps"].asJsonArray.withIndex()) {
            val step = stepEl.obj
            val at = step["at"].numOrNull() ?: 0.0
            val label = "${vector["id"].asString}.step${i + 1}(${step["do"].asString}@$at)"
            var lastResolution: RestResolution? = null

            when (step["do"].asString) {
                "setCompleted", "setFailed" -> {
                    val inputs = step["resolveInputs"].obj
                    lastResolution = RestResolver.resolve(
                        perSetSec = inputs["perSetSec"].intOrNull(),
                        perExerciseSec = inputs["perExerciseSec"].intOrNull(),
                        perRoutineSec = inputs["perRoutineSec"].intOrNull(),
                        categoryIsCompound = inputs["categoryIsCompound"].asBoolean,
                        settings = settingsDefaults,
                    )
                    val expectedResolution = step["expect"]?.obj?.get("resolution")
                    if (expectedResolution != null && !expectedResolution.isJsonNull) {
                        val er = expectedResolution.obj
                        checks.eq(lastResolution.durationSec, er["durationSec"].asInt, "$label.resolution.durationSec")
                        checks.eq(lastResolution.source.raw, er["source"].asString, "$label.resolution.source")
                    }
                    val action = if (step["do"].asString == "setCompleted")
                        RestAction.SetCompleted(lastResolution, step["allSetsTerminal"].asBoolean, at)
                    else
                        RestAction.SetFailed(lastResolution, step["allSetsTerminal"].asBoolean, at)
                    cycle.dispatch(action)?.let { cues.add(it.raw) }
                }
                "setDropped" -> cycle.dispatch(RestAction.SetDropped)?.let { cues.add(it.raw) }
                "skip" -> cycle.dispatch(RestAction.Skip(at))?.let { cues.add(it.raw) }
                "adjustSec" -> cycle.dispatch(RestAction.AdjustSec(step["delta"].asInt, at))?.let { cues.add(it.raw) }
                "expireNaturally" -> cycle.dispatch(RestAction.ExpireNaturally(at))?.let { cues.add(it.raw) }
                "backgrounded" -> cycle.dispatch(RestAction.Backgrounded(at))?.let { cues.add(it.raw) }
                else -> checks.fail("$label: unknown step ${step["do"].asString}")
            }

            val ex = step["expect"]?.takeIf { !it.isJsonNull }?.obj
            var ok = true
            if (ex != null && ex.has("state") && cycle.state.kind != ex["state"].asString) {
                ok = false
                checks.fail("$label: state=${cycle.state.kind} expected ${ex["state"].asString}")
            }
            if (ok && ex != null && ex.has("overlay") && cycle.overlay.raw != ex["overlay"].asString) {
                ok = false
                checks.fail("$label: overlay=${cycle.overlay.raw} expected ${ex["overlay"].asString}")
            }
            val st = cycle.state
            if (ok && ex != null && ex.has("durationSec")) {
                val dur = (st as? RestCycle.State.RestRunning)?.durationSec
                    ?: (st as? RestCycle.State.RestExpired)?.durationSec
                if (dur != ex["durationSec"].intOrNull()) {
                    ok = false
                    checks.fail("$label: durationSec=$dur expected ${ex["durationSec"].intOrNull()}")
                }
            }
            if (ok && ex != null && ex.has("startedAt")) {
                val started = (st as? RestCycle.State.RestRunning)?.startedAt
                    ?: (st as? RestCycle.State.RestExpired)?.startedAt
                if (started != ex["startedAt"].numOrNull()) {
                    ok = false
                    checks.fail("$label: startedAt=$started expected ${ex["startedAt"].numOrNull()}")
                }
            }
            if (ok && ex != null && ex.has("adjustmentSec")) {
                val adj = (st as? RestCycle.State.RestRunning)?.adjustmentSec
                    ?: (st as? RestCycle.State.RestExpired)?.adjustmentSec
                if (adj != ex["adjustmentSec"].intOrNull()) {
                    ok = false
                    checks.fail("$label: adjustmentSec=$adj expected ${ex["adjustmentSec"].intOrNull()}")
                }
            }
            if (ok && ex != null && ex.has("remainingSec")) {
                val rem = if (st is RestCycle.State.RestRunning)
                    RestCycle.remainingSec(st.durationSec, st.startedAt, st.adjustmentSec, at)
                else null
                if (rem != ex["remainingSec"].intOrNull()) {
                    ok = false
                    checks.fail("$label: remaining=$rem expected ${ex["remainingSec"].intOrNull()}")
                }
            }
            if (ok && ex != null && ex.has("cue")) {
                val expectedCue = ex["cue"].strOrNull()
                val got = cues.lastOrNull()
                if (got != expectedCue) {
                    ok = false
                    checks.fail("$label: cue=$got expected $expectedCue")
                }
            }
            if (ok) checks.pass(label)
        }

        val fin = vector["finalExpect"]?.takeIf { !it.isJsonNull }?.obj ?: com.google.gson.JsonObject()
        val vid = vector["id"].asString
        if (fin.has("state")) {
            if (cycle.state.kind == fin["state"].asString) checks.pass("$vid.final.state")
            else checks.fail("$vid.final: state=${cycle.state.kind} expected ${fin["state"].asString}")
        }
        if (fin.has("overlay")) {
            if (cycle.overlay.raw == fin["overlay"].asString) checks.pass("$vid.final.overlay")
            else checks.fail("$vid.final: overlay=${cycle.overlay.raw} expected ${fin["overlay"].asString}")
        }
        if (fin.has("adjustmentSec")) {
            val st = cycle.state
            val adj = (st as? RestCycle.State.RestRunning)?.adjustmentSec
                ?: (st as? RestCycle.State.RestExpired)?.adjustmentSec
            checks.eq(adj, fin["adjustmentSec"].intOrNull(), "$vid.final.adjustmentSec")
        }
        if (fin.has("remainingSec") && cycle.state is RestCycle.State.RestRunning) {
            val st = cycle.state as RestCycle.State.RestRunning
            val lastAt = vector["steps"].asJsonArray.last().obj["at"].numOrNull() ?: 0.0
            val rem = RestCycle.remainingSec(st.durationSec, st.startedAt, st.adjustmentSec, lastAt)
            checks.eq(rem, fin["remainingSec"].intOrNull(), "$vid.final.remainingSec")
        }
        if (fin.has("cues")) {
            val want = fin["cues"].asJsonArray.map { it.asString }
            checks.eq(cues, want, "$vid.final.cues")
        }
        if (fin.has("persistenceUnchanged") && fin["persistenceUnchanged"].asBoolean && before != null && db != null && snapshotTable != null) {
            val after = snapshotTable(db, snapshotTable)
            if (before == after) checks.pass("$vid.persistenceUnchanged")
            else checks.fail("$vid: $snapshotTable changed across the run (INV-T2 violated)")
        }
    }

    // MARK: - Tests

    @Test
    fun `sanity - required tables exist across the rest chain`() {
        val checks = Checks("Rest.sanity")
        freshDb().use { db ->
            val tables = db.tableNames()
            for (t in listOf("planned_set", "routine", "app_setting")) {
                checks.ok(t in tables, "table.$t.exists")
            }
        }
        checks.flush()
    }

    @Test
    fun `FSM fixtures BR-001 through BR-008 and INV-T6 pass`() {
        val checks = Checks("Rest.fsm")
        val fsmFixtures = listOf(
            "duration-hierarchy.json",
            "oneoff-adjust.json",
            "skip-gesture.json",
            "restart-on-mid-rest-completion.json",
            "drop-no-rest.json",
            "final-set-and-finish-morph.json",
            "recompute-on-kill.json",
            "rest-end-cue.json",
            "duration-clamp.json",
            "forward-compat-suppress.json",
        )
        for (name in fsmFixtures) {
            val fixture = Fixtures.json("rest", name)
            for (vectorEl in fixture["vectors"].asJsonArray) {
                runFsmSteps(checks, fixture, vectorEl.obj, null)
            }
        }
        checks.flush()
    }

    @Test
    fun `persistence vector V13 - defaults seed upsert and INV-S2 re-seed`() {
        val checks = Checks("Rest.persistence")
        val fixture = Fixtures.json("rest", "rest-settings-persistence.json")
        val vector = fixture["vectors"].asJsonArray[0].obj
        freshDb().use { db ->
            // Table/column shape claims from the fixture header.
            val shape = fixture["database"].obj["assertTableShape"].obj
            val cols = db.tableColumns(shape["name"].asString)
            val names = cols.map { it["name"] as String }
            for (c in shape["columns"].asJsonArray.map { it.asString }) {
                checks.ok(c in names, "schema.${shape["name"].asString}.$c.exists")
            }
            val pk = cols.filter { (it["pk"] as Number).toInt() > 0 }
                .sortedBy { (it["pk"] as Number).toInt() }
                .map { it["name"] as String }
            checks.eq(pk, shape["primaryKey"].asJsonArray.map { it.asString },
                "schema.${shape["name"].asString}.primaryKey")

            for (addEl in fixture["database"].obj["assertColumnAdded"].asJsonArray) {
                val add = addEl.obj
                val tableCols = db.tableColumns(add["table"].asString)
                val col = tableCols.firstOrNull { it["name"] == add["column"].asString }
                if (col == null) {
                    checks.fail("schema: ${add["table"].asString}.${add["column"].asString} missing")
                    continue
                }
                checks.eq(col["type"], add["type"].asString,
                    "schema.${add["table"].asString}.${add["column"].asString}.type")
                checks.eq((col["notnull"] as Number).toInt() == 0, add["nullable"].asBoolean,
                    "schema.${add["table"].asString}.${add["column"].asString}.nullable")
            }

            fun readUpdatedAt(key: String): String? =
                db.queryOne("SELECT updatedAt FROM app_setting WHERE key=?", key)?.get("updatedAt") as String?

            var lastBeforeUpdatedAt: String? = null
            for ((i, stepEl) in vector["steps"].asJsonArray.withIndex()) {
                val step = stepEl.obj
                val label = "${vector["id"].asString}.step${i + 1}(${step["do"].asString})"
                when (step["do"].asString) {
                    "fetchSettings" -> {
                        val got = fetchSettings(db)
                        val want = step["expect"].obj["settings"].obj
                        checks.eq(got["defaultRestCompoundSec"], want["defaultRestCompoundSec"].asInt, "$label.compound")
                        checks.eq(got["defaultRestIsolationSec"], want["defaultRestIsolationSec"].asInt, "$label.isolation")
                    }
                    "updateSettings" -> {
                        val before = readUpdatedAt("defaultRestCompoundSec")
                        // Deterministic later timestamp than the migration seed.
                        val bumped = step["at"]?.strOrNull()
                            ?: java.time.Instant.now().plusSeconds(1).toString()
                        updateSettings(db,
                            step["compoundSec"].intOrNull(), step["isolationSec"].intOrNull(), bumped)
                        lastBeforeUpdatedAt = before
                        val got = fetchSettings(db)
                        val want = step["expect"].obj["settings"].obj
                        checks.eq(got["defaultRestCompoundSec"], want["defaultRestCompoundSec"].asInt, "$label.compound")
                        checks.eq(got["defaultRestIsolationSec"], want["defaultRestIsolationSec"].asInt, "$label.isolation")
                    }
                    "assertUpdatedAtBumped" -> {
                        val after = readUpdatedAt(step["key"].asString)
                        checks.ok(after != null && after != lastBeforeUpdatedAt,
                            "$label (before=$lastBeforeUpdatedAt after=$after)")
                    }
                    "reapplyMigrations" -> {
                        // INV-S2: the idempotent seed tail of 0007 must not reset the user's value.
                        for (stmt in TestDb.splitStatements(settingsSeedSql)) db.exec(stmt)
                        checks.pass(label)
                    }
                    else -> checks.fail("$label: unknown persistence step ${step["do"].asString}")
                }
            }

            val fin = vector["finalExpect"]?.obj
            val got = fetchSettings(db)
            if (fin != null && fin.has("settings")) {
                val want = fin["settings"].obj
                checks.eq(got["defaultRestCompoundSec"], want["defaultRestCompoundSec"].asInt, "${vector["id"].asString}.final.compound")
                checks.eq(got["defaultRestIsolationSec"], want["defaultRestIsolationSec"].asInt, "${vector["id"].asString}.final.isolation")
            }
        }
        checks.flush()
    }

    @Test
    fun `persistence checks that need a DB snapshot - V5 INV-T2`() {
        val checks = Checks("Rest.snapshot")
        val adjustFixture = Fixtures.json("rest", "oneoff-adjust.json")
        for (vectorEl in adjustFixture["vectors"].asJsonArray) {
            val vector = vectorEl.obj
            if (vector["finalExpect"]?.obj?.has("persistenceUnchanged") == true) {
                freshDb().use { db ->
                    runFsmSteps(checks, adjustFixture, vector, db)
                }
            }
        }
        checks.flush()
    }
}
