// SC-settings@1.0.0 fixture runner (ticket #31 Stage A).
// Kotlin mirror of Tests/MooreSettingsTests/VerifySettings.mjs: full migration
// full canonical chain 0001–0011 (#32), fresh DB per vector, the SAME step executor
// over the ported com.moore.settings.SettingsEngine + a JDBC seam-2 harness.
// The backup round-trip uses VACUUM INTO (the SQLite full-file copy that the
// SAF export ships on Android).
package com.moore.core

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive
import com.moore.settings.SettingsEngine
import com.moore.settings.WeightUnit
import com.moore.test.Checks
import com.moore.test.Fixtures
import com.moore.test.MigrationChain
import com.moore.test.TestDb
import com.moore.test.intOrNull
import com.moore.test.numOrNull
import com.moore.test.obj
import com.moore.test.strOrNull
import org.junit.Test
import java.io.File
import java.util.UUID

class SettingsFixtureTest {

    private val seedNow = "2026-08-13T08:00:00Z"

    private val restSeedSql = """
        INSERT OR IGNORE INTO app_setting (key, value, updatedAt) VALUES
          ('defaultRestCompoundSec',  '180', strftime('%Y-%m-%dT%H:%M:%fZ','now')),
          ('defaultRestIsolationSec', '90',  strftime('%Y-%m-%dT%H:%M:%fZ','now'));
    """.trimIndent()

    // MARK: - DB plumbing

    private fun newDbFull(): TestDb {
        val db = TestDb()
        db.applyAll(*MigrationChain.SETTINGS_FULL)
        return db
    }

    /// Apply everything up to 0009, seed legacy-shape rows, THEN apply 0009 —
    /// proving the rebuild remap + preservation on live data.
    private fun newDbStaged(fixture: JsonObject): TestDb {
        val db = TestDb()
        val pre = MigrationChain.SETTINGS_FULL.dropLast(1).toTypedArray()
        db.applyAll(*pre)
        fixture["legacySeed"]?.obj?.get("bodyMetrics")?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val m = el.obj
            db.insert("body_metric", mapOf(
                "id" to m["id"].asString, "kind" to m["kind"].asString,
                "value" to m["value"].asDouble, "unit" to m["unit"].asString,
                "recordedAt" to m["recordedAt"].asString,
                "createdAt" to m["createdAt"].asString, "updatedAt" to m["updatedAt"].asString))
        }
        db.applyMigration(MigrationChain.SETTINGS_FULL.last())
        return db
    }

    private fun seedFixture(db: TestDb, fx: JsonObject) {
        val s = fx["seed"]?.obj ?: return
        val now = seedNow
        s["folders"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val r = el.obj
            db.insert("folder", mapOf("id" to r["id"].asString, "name" to r["name"].asString,
                "createdAt" to now, "updatedAt" to now, "deletedAt" to r["deletedAt"].strOrNull()))
        }
        s["exercises"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val r = el.obj
            db.insert("exercise", mapOf("id" to r["id"].asString, "name" to r["name"].asString,
                "exerciseType" to r["exerciseType"].asString, "isCustom" to (r["isCustom"]?.asInt ?: 0),
                "createdAt" to now, "updatedAt" to now, "deletedAt" to r["deletedAt"].strOrNull()))
        }
        s["routines"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val r = el.obj
            db.insert("routine", mapOf("id" to r["id"].asString, "folderId" to r["folderId"].strOrNull(),
                "name" to r["name"].asString, "sortOrder" to (r["sortOrder"]?.asInt ?: 0),
                "createdAt" to now, "updatedAt" to now, "deletedAt" to r["deletedAt"].strOrNull()))
        }
        s["plannedSets"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val r = el.obj
            db.insert("planned_set", mapOf("id" to r["id"].asString, "routineId" to r["routineId"].asString,
                "exerciseId" to r["exerciseId"].asString, "sortOrder" to (r["sortOrder"]?.asInt ?: 0),
                "plannedWeight" to r["plannedWeight"].numOrNull(), "plannedReps" to r["plannedReps"].intOrNull(),
                "plannedDuration" to r["plannedDuration"].intOrNull(),
                "createdAt" to now, "updatedAt" to now, "deletedAt" to r["deletedAt"].strOrNull()))
        }
        s["sessions"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val r = el.obj
            db.insert("workout_session", mapOf("id" to r["id"].asString, "startedAt" to r["startedAt"].asString,
                "endedAt" to r["endedAt"].strOrNull(), "createdAt" to now, "updatedAt" to now,
                "deletedAt" to r["deletedAt"].strOrNull()))
        }
        var ord = 0
        s["completedSets"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val r = el.obj
            db.insert("completed_set", mapOf("id" to r["id"].asString, "sessionId" to r["sessionId"].asString,
                "exerciseId" to r["exerciseId"].asString, "sortOrder" to ord++,
                "plannedWeight" to r["plannedWeight"].numOrNull(), "plannedReps" to r["plannedReps"].intOrNull(),
                "plannedDuration" to r["plannedDuration"].intOrNull(),
                "actualWeight" to r["actualWeight"].numOrNull(), "actualReps" to r["actualReps"].intOrNull(),
                "actualDuration" to r["actualDuration"].intOrNull(),
                "status" to r["status"].asString, "completedAt" to r["completedAt"].strOrNull(),
                "createdAt" to now, "updatedAt" to now, "deletedAt" to r["deletedAt"].strOrNull()))
        }
        s["personalRecords"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val r = el.obj
            db.insert("personal_record", mapOf("id" to r["id"].asString, "exerciseId" to r["exerciseId"].asString,
                "sessionId" to r["sessionId"].asString, "setId" to r["setId"].strOrNull(),
                "kind" to r["kind"].asString, "value" to r["value"].asDouble,
                "achievedAt" to r["achievedAt"].asString, "createdAt" to now, "updatedAt" to now))
        }
        s["bodyMetrics"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val r = el.obj
            db.insert("body_metric", mapOf("id" to r["id"].asString, "kind" to r["kind"].asString,
                "label" to r["label"].strOrNull(), "value" to r["value"].asDouble, "unit" to r["unit"].asString,
                "recordedAt" to r["recordedAt"].asString, "createdAt" to now, "updatedAt" to now,
                "deletedAt" to r["deletedAt"].strOrNull()))
        }
        s["progressionSchemes"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { el ->
            val r = el.obj
            db.insert("progression_scheme", mapOf("id" to r["id"].asString, "routineId" to r["routineId"].asString,
                "exerciseId" to r["exerciseId"].asString, "scheme" to r["scheme"].asString,
                "incrementValue" to r["incrementValue"].numOrNull(), "createdAt" to now, "updatedAt" to now))
        }
        val wu = s["settings"]?.obj?.get("weightUnit")?.strOrNull()
        if (wu != null) upsertSetting(db, "weightUnit", wu, now)
    }

    private fun upsertSetting(db: TestDb, key: String, value: String, at: String) {
        db.update("""
            INSERT INTO app_setting (key, value, updatedAt) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
        """.trimIndent(), key, value, at)
    }

    private fun fetchSettings(db: TestDb): Map<String, Any> {
        fun value(key: String): String? =
            db.queryOne("SELECT value FROM app_setting WHERE key = ?", key)?.get("value") as String?
        val wu = value("weightUnit")
        return mapOf(
            "weightUnit" to (if (wu == "kg" || wu == "lb") wu else "kg"),   // BR-014 fallback
            "defaultRestCompoundSec" to (value("defaultRestCompoundSec")?.toIntOrNull() ?: 180),
            "defaultRestIsolationSec" to (value("defaultRestIsolationSec")?.toIntOrNull() ?: 90),
        )
    }

    // MARK: - JSON building helpers

    private fun toJsonAny(v: Any?): JsonElement = when (v) {
        null -> JsonNull.INSTANCE
        is Boolean -> JsonPrimitive(v)
        is Int, is Long -> JsonPrimitive((v as Number).toLong())
        is Number -> {
            val d = v.toDouble()
            if (d == kotlin.math.floor(d) && !d.isInfinite()) JsonPrimitive(d.toLong()) else JsonPrimitive(d)
        }
        is String -> JsonPrimitive(v)
        is Map<*, *> -> JsonObject().also { o ->
            @Suppress("UNCHECKED_CAST")
            (v as Map<String, Any?>).forEach { (k, value) -> o.add(k, toJsonAny(value)) }
        }
        is List<*> -> JsonArray().also { a -> v.forEach { a.add(toJsonAny(it)) } }
        else -> JsonPrimitive(v.toString())
    }

    private fun copyTables(): Map<String, Map<String, String>> = mapOf(
        "emptyStateCopy" to SettingsEngine.emptyStateCopy,
        "foundationDbCopy" to SettingsEngine.foundationDbCopy,
        "settingsCopy" to SettingsEngine.settingsCopy,
    )

    // MARK: - Export round-trip (seam-2 AC: backup DB hash matches original)

    private fun tableNamesOf(db: TestDb): List<String> = db.tableNames()

    private fun hasDeletedAtColumn(db: TestDb, table: String): Boolean =
        db.tableColumns(table).any { it["name"] == "deletedAt" }

    private fun exportSelectDumps(db: TestDb): List<SettingsEngine.TableStats> {
        return tableNamesOf(db).map { table ->
            val rowCount = (db.queryOne("SELECT COUNT(*) AS n FROM \"$table\"")?.get("n") as Number).toInt()
            val tombstoneCount = if (hasDeletedAtColumn(db, table))
                (db.queryOne("SELECT COUNT(*) AS n FROM \"$table\" WHERE deletedAt IS NOT NULL")?.get("n") as Number).toInt()
            else 0
            SettingsEngine.TableStats(table, rowCount, tombstoneCount)
        }
    }

    /// Deterministic logical-content digest for the round-trip hash assertion.
    private fun contentHash(db: TestDb): String {
        val parts = mutableListOf<String>()
        for (t in db.query("SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")) {
            val name = t["name"] as String
            parts.add("TABLE $name\n${t["sql"]}")
            for (row in db.query("SELECT * FROM \"$name\" ORDER BY rowid")) {
                parts.add(Checks.canonical(toJsonAny(row)))
            }
        }
        for (i in db.query("SELECT name, sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY name")) {
            parts.add("INDEX ${i["name"]}\n${i["sql"]}")
        }
        return db.sha256(parts.joinToString("\n"))
    }

    private fun schemaShape(db: TestDb): Map<String, List<String>> {
        val shape = LinkedHashMap<String, List<String>>()
        for (t in tableNamesOf(db)) {
            shape[t] = db.tableColumns(t).map { it["name"] as String }.sorted()
        }
        return shape
    }

    private fun runExportRoundTrip(checks: Checks, db: TestDb, expect: JsonObject, label: String) {
        val tmpFile = File.createTempFile("moore-roundtrip-", ".moore-backup")
        tmpFile.delete() // VACUUM INTO requires the target to not exist
        newDbFull().use { fresh ->
            try {
                db.exec("VACUUM INTO '${tmpFile.absolutePath.replace("'", "''")}'")
                TestDb::class.java // keep
                val copyConn = java.sql.DriverManager.getConnection("jdbc:sqlite:${tmpFile.absolutePath}")
                val copy = TestDbWrap(copyConn)
                try {
                    // 1. Per-table row counts match — tombstones included (INV-ST3).
                    var countsOk = true
                    for (table in tableNamesOf(db)) {
                        val a = (db.queryOne("SELECT COUNT(*) AS n FROM \"$table\"")?.get("n") as Number).toInt()
                        val b = (copy.queryOne("SELECT COUNT(*) AS n FROM \"$table\"")?.get("n") as Number).toInt()
                        if (a != b) {
                            countsOk = false
                            checks.fail("$label.rowCounts.$table: original=$a copy=$b")
                        }
                    }
                    if (countsOk) checks.pass("$label.rowCountsMatch")

                    // 2. Logical content hash matches (the seam-2 hash assertion).
                    val hOrig = contentHash(db)
                    val hCopy = contentHashOf(copy)
                    if (hOrig == hCopy) checks.pass("$label.contentHashMatches")
                    else checks.fail("$label.contentHash: $hCopy != $hOrig")

                    // 3. Integrity.
                    val integrity = copy.queryOne("PRAGMA integrity_check")?.values?.firstOrNull()
                    if (integrity == "ok") checks.pass("$label.integrityOk")
                    else checks.fail("$label.integrity: $integrity")

                    // 4. The copy's schema shape equals a freshly-migrated DB's shape.
                    checks.deepEq(toJsonAny(schemaShapeOf(copy)), toJsonAny(schemaShape(fresh)),
                        "$label.schemaShapeMatchesFreshDb")

                    // 5. Tombstones + NULL plannedX survived the trip.
                    expect["tombstonedExerciseSurvives"]?.strOrNull()?.let { id ->
                        val row = copy.queryOne("SELECT deletedAt FROM exercise WHERE id = ?", id)
                        checks.ok(row != null && row["deletedAt"] != null, "$label.tombstonedExerciseSurvives")
                    }
                    expect["tombstonedSetSurvives"]?.strOrNull()?.let { id ->
                        val row = copy.queryOne("SELECT deletedAt, plannedWeight FROM completed_set WHERE id = ?", id)
                        checks.ok(row != null && row["deletedAt"] != null, "$label.tombstonedSetSurvives")
                        if (expect["nullPlannedColumnsSurvive"]?.strOrNull() == id) {
                            checks.ok(row != null && row["plannedWeight"] == null, "$label.nullPlannedColumnsSurvive")
                        }
                    }
                    expect["tombstonedMetricSurvives"]?.strOrNull()?.let { id ->
                        val row = copy.queryOne("SELECT deletedAt FROM body_metric WHERE id = ?", id)
                        checks.ok(row != null && row["deletedAt"] != null, "$label.tombstonedMetricSurvives")
                    }
                } finally {
                    copyConn.close()
                }
            } finally {
                tmpFile.delete()
            }
        }
    }

    /// Thin wrappers so the round-trip can reuse the helpers over any connection.
    private class TestDbWrap(val conn: java.sql.Connection) {
        fun queryOne(sql: String, vararg params: Any?): Map<String, Any?>? {
            conn.prepareStatement(sql).use { ps ->
                params.forEachIndexed { i, p -> ps.setObject(i + 1, p) }
                ps.executeQuery().use { rs ->
                    val meta = rs.metaData
                    val cols = (1..meta.columnCount).map { meta.getColumnLabel(it) }
                    if (!rs.next()) return null
                    val row = LinkedHashMap<String, Any?>()
                    cols.forEachIndexed { i, c -> row[c] = rs.getObject(i + 1) }
                    return row
                }
            }
        }
    }

    private fun contentHashOf(wrap: TestDbWrap): String {
        // Reuse the canonical digest over the wrapped connection via a TestDb-free path.
        val parts = mutableListOf<String>()
        fun q(sql: String): List<Map<String, Any?>> {
            wrap.conn.prepareStatement(sql).use { ps ->
                ps.executeQuery().use { rs ->
                    val meta = rs.metaData
                    val cols = (1..meta.columnCount).map { meta.getColumnLabel(it) }
                    val out = mutableListOf<Map<String, Any?>>()
                    while (rs.next()) {
                        val row = LinkedHashMap<String, Any?>()
                        cols.forEachIndexed { i, c -> row[c] = rs.getObject(i + 1) }
                        out.add(row)
                    }
                    return out
                }
            }
        }
        for (t in q("SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")) {
            val name = t["name"] as String
            parts.add("TABLE $name\n${t["sql"]}")
            for (row in q("SELECT * FROM \"$name\" ORDER BY rowid")) {
                parts.add(Checks.canonical(toJsonAny(row)))
            }
        }
        for (i in q("SELECT name, sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY name")) {
            parts.add("INDEX ${i["name"]}\n${i["sql"]}")
        }
        return java.security.MessageDigest.getInstance("SHA-256")
            .digest(parts.joinToString("\n").toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    private fun schemaShapeOf(wrap: TestDbWrap): Map<String, List<String>> {
        fun q(sql: String): List<Map<String, Any?>> {
            wrap.conn.prepareStatement(sql).use { ps ->
                ps.executeQuery().use { rs ->
                    val meta = rs.metaData
                    val cols = (1..meta.columnCount).map { meta.getColumnLabel(it) }
                    val out = mutableListOf<Map<String, Any?>>()
                    while (rs.next()) {
                        val row = LinkedHashMap<String, Any?>()
                        cols.forEachIndexed { i, c -> row[c] = rs.getObject(i + 1) }
                        out.add(row)
                    }
                    return out
                }
            }
        }
        val shape = LinkedHashMap<String, List<String>>()
        val tables = q("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .map { it["name"] as String }
        for (t in tables) {
            shape[t] = q("PRAGMA table_info(\"$t\")").map { it["name"] as String }.sorted()
        }
        return shape
    }

    // MARK: - Step executor

    private fun runSteps(checks: Checks, db: TestDb, fixture: JsonObject, vector: JsonObject) {
        val snapshots = HashMap<String, String>()
        val priorSettingUpdatedAt = HashMap<String, String?>()

        for ((i, stepEl) in (vector["steps"]?.asJsonArray ?: JsonArray()).withIndex()) {
            val step = stepEl.obj
            val id = "${fixture["fixture"].asString}.${vector["id"].asString}.step${i + 1}(${step["do"].asString})"
            when (step["do"].asString) {
                // ---- Engine mirror steps (pure) ----
                "kgToLb" -> checks.approx(SettingsEngine.kgToLb(step["kg"].asDouble), step["expect"].asDouble, id)
                "lbToKg" -> checks.approx(SettingsEngine.lbToKg(step["lb"].asDouble), step["expect"].asDouble, id)
                "roundDisplay" -> checks.approx(SettingsEngine.roundDisplay(step["value"].asDouble), step["expect"].asDouble, id)
                "roundStorage" -> checks.approx(SettingsEngine.roundStorage(step["value"].asDouble), step["expect"].asDouble, id)
                "displayString" -> checks.eq(
                    SettingsEngine.displayString(step["rawKg"].asDouble, WeightUnit.fromRaw(step["unit"].asString)!!),
                    step["expect"].asString, id)
                "entryToStorage" -> checks.approx(
                    SettingsEngine.entryToStorage(step["entered"].asDouble, WeightUnit.fromRaw(step["unit"].asString)!!),
                    step["expectKg"].asDouble, id)

                "cloudSyncStatus" -> {
                    val s = SettingsEngine.cloudSyncStatus
                    checks.deepEq(toJsonAny(mapOf("enabled" to s.enabled, "greyed" to s.greyed,
                        "copyKey" to s.copyKey, "infoIssue" to s.infoIssue)), step["expect"], id)
                }
                "hevyImportEntry" -> {
                    val s = SettingsEngine.hevyImportEntry
                    checks.deepEq(toJsonAny(mapOf("enabled" to s.enabled,
                        "blockedByTicket" to s.blockedByTicket, "copyKey" to s.copyKey)), step["expect"], id)
                }

                "assertCopyTable" -> {
                    val table = copyTables()[step["table"].asString]!!
                    checks.deepEq(toJsonAny(table), step["expect"], id)
                }
                "assertCopyTableComplete" -> {
                    val table = copyTables()[step["table"].asString]!!
                    var ok = true
                    for (keyEl in step["keys"].asJsonArray) {
                        val key = keyEl.asString
                        val v = table[key]
                        if (v.isNullOrEmpty()) {
                            ok = false
                            checks.fail("$id: key $key missing or empty")
                        }
                    }
                    if (ok) checks.pass(id)
                }
                "assertCopyValue" -> checks.eq(
                    copyTables()[step["table"].asString]!![step["key"].asString], step["expect"].asString, id)

                // ---- Settings persistence ----
                "fetchSettings" -> checks.deepEq(toJsonAny(fetchSettings(db)), step["expect"], id)
                "setWeightUnit" -> {
                    upsertSetting(db, "weightUnit", step["unit"].asString, step["at"].asString)
                    checks.pass(id)
                }
                "updateRestDefaults" -> {
                    for ((key, v) in listOf(
                        "defaultRestCompoundSec" to step["compoundSec"].intOrNull(),
                        "defaultRestIsolationSec" to step["isolationSec"].intOrNull())) {
                        if (v != null) {
                            priorSettingUpdatedAt[key] =
                                db.queryOne("SELECT updatedAt FROM app_setting WHERE key = ?", key)?.get("updatedAt") as String?
                        }
                    }
                    step["compoundSec"].intOrNull()?.let { upsertSetting(db, "defaultRestCompoundSec", it.toString(), step["at"].asString) }
                    step["isolationSec"].intOrNull()?.let { upsertSetting(db, "defaultRestIsolationSec", it.toString(), step["at"].asString) }
                    if (step.has("expect")) checks.deepEq(toJsonAny(fetchSettings(db)), step["expect"], id)
                    else checks.pass(id)
                }
                "assertSettingUpdatedAtBumped" -> {
                    val after = db.queryOne("SELECT updatedAt FROM app_setting WHERE key = ?", step["key"].asString)
                        ?.get("updatedAt") as String?
                    val before = priorSettingUpdatedAt[step["key"].asString]
                    checks.ok(after != null && after != before, "$id (before=$before after=$after)")
                }
                "assertSettingsRowCount" -> checks.eq(
                    (db.queryOne("SELECT COUNT(*) AS n FROM app_setting")?.get("n") as Number).toInt(),
                    step["expect"].asInt, id)
                "assertSettingsRowCountForKeys" -> {
                    val keys = step["keys"].asJsonArray.map { it.asString }
                    val placeholders = keys.joinToString(",") { "?" }
                    val n = (db.queryOne("SELECT COUNT(*) AS n FROM app_setting WHERE key IN ($placeholders)", *keys.toTypedArray())
                        ?.get("n") as Number).toInt()
                    checks.eq(n, step["expect"].asInt, id)
                }
                "reapplyRestSeed" -> {
                    for (stmt in TestDb.splitStatements(restSeedSql)) db.exec(stmt)
                    checks.pass(id)
                }

                // ---- Body metrics CRUD ----
                "addBodyMetric" -> {
                    val err = SettingsEngine.validateBodyMetric(
                        kind = step["kind"].asString,
                        label = step["label"].strOrNull(),
                        value = step["value"].asDouble,
                        unit = step["unit"].asString,
                    )
                    if (step.has("expectError")) {
                        checks.eq(err?.code, step["expectError"].asString, id)
                    } else {
                        if (err != null) checks.fail("$id: unexpected error ${err.code}")
                        else {
                            val metricId = step["id"]?.strOrNull() ?: UUID.randomUUID().toString()
                            db.insert("body_metric", mapOf(
                                "id" to metricId, "kind" to step["kind"].asString,
                                "label" to if (step["kind"].asString == "measurement") step["label"].strOrNull() else null,
                                "value" to step["value"].asDouble, "unit" to step["unit"].asString,
                                "recordedAt" to step["recordedAt"].asString,
                                "createdAt" to step["at"].asString, "updatedAt" to step["at"].asString,
                                "deletedAt" to null))
                            checks.pass(id)
                        }
                    }
                }
                "listBodyMetrics" -> {
                    val rows = if (step.has("kind") && !step["kind"].isJsonNull)
                        db.query("SELECT * FROM body_metric WHERE deletedAt IS NULL AND kind = ? ORDER BY recordedAt DESC, createdAt DESC",
                            step["kind"].asString)
                    else
                        db.query("SELECT * FROM body_metric WHERE deletedAt IS NULL ORDER BY recordedAt DESC, createdAt DESC")
                    val mapped = rows.map { r ->
                        val out = LinkedHashMap<String, Any?>()
                        out["kind"] = r["kind"]
                        out["value"] = r["value"]
                        out["unit"] = r["unit"]
                        out["recordedAt"] = r["recordedAt"]
                        if (r["label"] != null) out["label"] = r["label"]
                        out
                    }
                    checks.deepEq(toJsonAny(mapped), step["expect"], id)
                }
                "updateBodyMetric" -> {
                    val kind = db.queryOne("SELECT kind FROM body_metric WHERE id = ? AND deletedAt IS NULL", step["id"].asString)
                        ?.get("kind") as String?
                    val err = SettingsEngine.validateBodyMetric(
                        kind = kind ?: "", label = step["label"].strOrNull(),
                        value = step["value"].asDouble, unit = step["unit"].asString)
                    if (err != null) {
                        checks.fail("$id: validation ${err.code}")
                    } else {
                        db.update("""
                            UPDATE body_metric SET value = ?, unit = ?, label = ?, recordedAt = ?, updatedAt = ?
                            WHERE id = ? AND deletedAt IS NULL
                        """.trimIndent(), step["value"].asDouble, step["unit"].asString,
                            if (kind == "measurement") step["label"].strOrNull() else null,
                            step["recordedAt"].asString, step["at"].asString, step["id"].asString)
                        checks.pass(id)
                    }
                }
                "softDeleteBodyMetric" -> {
                    db.update("UPDATE body_metric SET deletedAt = ?, updatedAt = ? WHERE id = ? AND deletedAt IS NULL",
                        step["at"].asString, step["at"].asString, step["id"].asString)
                    checks.pass(id)
                }
                "assertBodyMetricUpdatedAt" -> checks.eq(
                    db.queryOne("SELECT updatedAt FROM body_metric WHERE id = ?", step["id"].asString)?.get("updatedAt"),
                    step["expect"].asString, id)
                "assertBodyMetricRawRow" -> {
                    val row = db.queryOne("SELECT * FROM body_metric WHERE id = ?", step["id"].asString)
                    checks.ok(row != null && row["deletedAt"] == step["expectDeletedAt"].strOrNull(),
                        "$id: row=$row")
                }
                "assertBodyMetricRawCount" -> checks.eq(
                    (db.queryOne("SELECT COUNT(*) AS n FROM body_metric")?.get("n") as Number).toInt(),
                    step["expect"].asInt, id)
                "assertBodyMetricRow" -> {
                    val row = db.queryOne("SELECT * FROM body_metric WHERE id = ?", step["id"].asString)
                    val got = row?.let {
                        mapOf("kind" to it["kind"], "label" to it["label"], "value" to it["value"], "unit" to it["unit"])
                    }
                    checks.deepEq(toJsonAny(got), step["expect"], id)
                }
                "assertBodyMetricColumns" -> checks.eq(
                    db.tableColumns("body_metric").map { it["name"] as String },
                    step["expect"].asJsonArray.map { it.asString }, id)
                "insertRawExpectCheckFailure" -> {
                    val threw = try {
                        db.insert("body_metric", mapOf(
                            "id" to UUID.randomUUID().toString(), "kind" to step["kind"].asString,
                            "value" to step["value"].asDouble, "unit" to step["unit"].asString,
                            "recordedAt" to step["recordedAt"].asString, "createdAt" to "t", "updatedAt" to "t"))
                        false
                    } catch (e: Exception) {
                        true
                    }
                    checks.ok(threw, "$id: kind='${step["kind"].asString}' must violate CHECK post-0011")
                }
                "assertTableExists" -> {
                    val t = db.queryOne("SELECT name FROM sqlite_master WHERE type='table' AND name = ?", step["table"].asString)
                    checks.ok(t != null, "$id: table ${step["table"].asString} missing")
                }
                "assertLegacyRawKind" -> checks.eq(
                    db.queryOne("SELECT kind FROM body_metric__legacy_0001 WHERE id = ?", step["id"].asString)?.get("kind"),
                    step["expect"].asString, id)

                // ---- Tombstone management ----
                "listTombstonedExercises" -> {
                    val rows = db.query("SELECT id, name, exerciseType, isCustom, deletedAt FROM exercise WHERE deletedAt IS NOT NULL")
                        .map {
                            SettingsEngine.ExerciseTombstoneRow(
                                id = it["id"] as String, name = it["name"] as String,
                                isCustom = (it["isCustom"] as Number).toInt(), deletedAt = it["deletedAt"] as String?)
                        }
                    val listed = SettingsEngine.tombstonedCustomExercises(rows).map {
                        mapOf<String, Any?>("id" to it.id, "name" to it.name, "deletedAt" to it.deletedAt)
                    }
                    checks.deepEq(toJsonAny(listed), step["expect"], id)
                }
                "restoreExercise" -> {
                    db.update("UPDATE exercise SET deletedAt = NULL, updatedAt = ? WHERE id = ? AND deletedAt IS NOT NULL",
                        step["at"].asString, step["id"].asString)
                    checks.pass(id)
                }
                "assertExerciseLive" -> {
                    val row = db.queryOne("SELECT deletedAt, updatedAt FROM exercise WHERE id = ?", step["id"].asString)
                    val expectUpdatedAt = step["expectUpdatedAt"].strOrNull()
                    checks.ok(row != null && row["deletedAt"] == null && (expectUpdatedAt == null || row["updatedAt"] == expectUpdatedAt),
                        "$id: row=$row")
                }
                "assertExerciseStillTombstoned" -> {
                    val row = db.queryOne("SELECT deletedAt FROM exercise WHERE id = ?", step["id"].asString)
                    checks.ok(row != null && row["deletedAt"] != null, "$id: row=$row")
                }
                "assertExerciseUntouched" -> {
                    // Restore on a live row is a no-op: still live, updatedAt unchanged.
                    val row = db.queryOne("SELECT deletedAt, updatedAt FROM exercise WHERE id = ?", step["id"].asString)
                    checks.ok(row != null && row["deletedAt"] == null && row["updatedAt"] == seedNow, "$id: row=$row")
                }

                // ---- Display pipelines (read settings live) ----
                "displayStoredWeight" -> {
                    val settings = fetchSettings(db)
                    val unit = WeightUnit.fromRaw(settings["weightUnit"] as String)!!
                    val raw = db.queryOne("SELECT ${step["column"].asString} AS w FROM completed_set WHERE id = ?",
                        step["setId"].asString)?.get("w") as? Number
                    val got = if (raw == null) null else SettingsEngine.displayString(raw.toDouble(), unit)
                    checks.eq(got, step["expect"].strOrNull(), id)
                }
                "displayBodyMetricRow" -> {
                    val settings = fetchSettings(db)
                    val target = WeightUnit.fromRaw(settings["weightUnit"] as String)!!
                    val row = db.queryOne("SELECT value, unit FROM body_metric WHERE id = ?", step["metricId"].asString)
                    val got = row?.let {
                        val value = (it["value"] as Number).toDouble()
                        val rowUnit = it["unit"] as String
                        val displayUnit = if (rowUnit == "kg" || rowUnit == "lb") target.raw else rowUnit
                        String.format(java.util.Locale.US, "%.1f %s",
                            SettingsEngine.displayBodyMetric(value, rowUnit, target), displayUnit)
                    }
                    checks.eq(got, step["expect"].strOrNull(), id)
                }

                // ---- Snapshots / display-only proof ----
                "snapshotTable" -> {
                    snapshots[step["table"].asString] =
                        db.query("SELECT * FROM \"${step["table"].asString}\" ORDER BY rowid").toString()
                    checks.pass(id)
                }
                "assertTableUnchanged" -> {
                    val now = db.query("SELECT * FROM \"${step["table"].asString}\" ORDER BY rowid").toString()
                    if (snapshots[step["table"].asString] == now) checks.pass(id)
                    else checks.fail("$id: ${step["table"].asString} rows changed (INV violation)")
                }
                "assertSessionCount" -> checks.eq(
                    (db.queryOne("SELECT COUNT(*) AS n FROM workout_session")?.get("n") as Number).toInt(),
                    step["expect"].asInt, id)

                // ---- Export ----
                "buildManifest" -> {
                    val exportedAt = vector["exportedAt"]?.strOrNull() ?: fixture["exportedAt"].asString
                    val manifest = SettingsEngine.buildExportManifest(exportSelectDumps(db), exportedAt)
                    val manifestJson = toJsonAny(mapOf(
                        "fileName" to manifest.fileName,
                        "exportedAt" to manifest.exportedAt,
                        "format" to manifest.format,
                        "includesTombstones" to manifest.includesTombstones,
                        "includesPlannedColumns" to manifest.includesPlannedColumns,
                        "tables" to manifest.tables.map {
                            mapOf("table" to it.table, "rowCount" to it.rowCount, "tombstoneCount" to it.tombstoneCount)
                        },
                    ))
                    val expected = JsonObject()
                    expected.addProperty("exportedAt", exportedAt)
                    step["expect"].obj.keySet().forEach { k -> expected.add(k, step["expect"].obj[k]) }
                    checks.deepEq(manifestJson, expected, id)
                }
                "assertLegacyTablesPresent" -> {
                    var ok = true
                    for (tEl in step["expect"].asJsonArray) {
                        val t = tEl.asString
                        val row = db.queryOne("SELECT name FROM sqlite_master WHERE type='table' AND name = ?", t)
                        if (row == null) {
                            ok = false
                            checks.fail("$id: legacy table $t missing")
                        }
                    }
                    if (ok) checks.pass(id)
                }
                "assertPlannedColumnsPresent" -> {
                    val cols = db.tableColumns(step["table"].asString).map { it["name"] as String }
                    val missing = step["columns"].asJsonArray.map { it.asString }.filter { it !in cols }
                    if (missing.isEmpty()) checks.pass(id)
                    else checks.fail("$id: missing columns ${missing.joinToString(", ")}")
                }
                "exportRoundTrip" -> runExportRoundTrip(checks, db, step["expect"]?.obj ?: JsonObject(), id)

                else -> checks.fail("$id: unknown step ${step["do"].asString}")
            }
        }
    }

    // MARK: - Schema sanity

    @Test
    fun `schema sanity across the full chain`() {
        val checks = Checks("Settings.schema")
        newDbFull().use { db ->
            for (t in listOf("app_setting", "body_metric", "body_metric__legacy_0001")) {
                val row = db.queryOne("SELECT name FROM sqlite_master WHERE type='table' AND name = ?", t)
                checks.ok(row != null, "schema.$t.exists")
            }
            val cols = db.tableColumns("body_metric").map { it["name"] as String }
            checks.ok("label" in cols, "schema.body_metric.label.exists")
            // Closed vocabulary: 'measurement' accepted, legacy 'weight' rejected.
            db.insert("body_metric", mapOf("id" to "sanity-m", "kind" to "measurement", "label" to "Waist",
                "value" to 84.0, "unit" to "cm", "recordedAt" to "t", "createdAt" to "t", "updatedAt" to "t"))
            checks.pass("schema.body_metric.measurement.accepted")
            val threw = try {
                db.insert("body_metric", mapOf("id" to "sanity-w", "kind" to "weight", "value" to 80.0,
                    "unit" to "kg", "recordedAt" to "t", "createdAt" to "t", "updatedAt" to "t"))
                false
            } catch (e: Exception) {
                true
            }
            checks.ok(threw, "schema.body_metric.legacy-kind-rejected")
        }
        checks.flush()
    }

    // MARK: - Fixture runner

    @Test
    fun `all settings fixtures pass on the ported engine and harness`() {
        val checks = Checks("Settings.fixtures")
        val files = listOf(
            "unit-conversion-math.json",
            "unit-toggle-display-only.json",
            "rest-defaults-persist.json",
            "bodymetric-add-list.json",
            "bodymetric-update-delete.json",
            "bodymetric-migration-shape.json",
            "export-manifest-completeness.json",
            "backup-roundtrip.json",
            "tombstone-list-restore.json",
            "cloud-sync-greyed.json",
            "hevy-import-stub.json",
            "empty-state-keys.json",
        )
        for (fname in files) {
            val fixture = Fixtures.json("settings", fname)
            for (vectorEl in fixture["vectors"]!!.asJsonArray) {
                val vector = vectorEl.obj
                // Fresh DB per vector: each vector is a self-contained acceptance scenario.
                val db = if (fixture["migrationMode"].strOrNull() == "staged") newDbStaged(fixture) else newDbFull()
                try {
                    if (fixture["migrationMode"].strOrNull() != "staged") seedFixture(db, fixture)
                    runSteps(checks, db, fixture, vector)
                } finally {
                    db.close()
                }
            }
        }
        checks.flush()
    }
}
