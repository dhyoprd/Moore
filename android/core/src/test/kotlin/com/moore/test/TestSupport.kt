// Shared test support for the parity suite (ticket #31 Stage A).
// Mirrors the Node verifier harnesses (Tests/*/Verify*.mjs): fixture loading,
// in-memory SQLite over the SAME .sql migrations, and check collection.
package com.moore.test

import com.google.gson.Gson
import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import java.security.MessageDigest
import java.sql.Connection
import java.sql.DriverManager
import java.sql.ResultSet

// MARK: - Fixture loading

object Fixtures {
    /// Read a fixture file copied verbatim from Tests/<Area>Tests/Fixtures/.
    fun text(area: String, name: String): String {
        val stream = Fixtures::class.java.getResourceAsStream("/fixtures/$area/$name")
            ?: error("fixture missing: fixtures/$area/$name")
        return stream.bufferedReader(Charsets.UTF_8).use { it.readText() }
    }

    fun json(area: String, name: String): JsonObject =
        JsonParser.parseString(text(area, name)).asJsonObject
}

// MARK: - JSON element helpers (Gson numbers are Doubles, like JS)

val JsonElement.obj: JsonObject get() = asJsonObject
val JsonElement.arr: JsonArray get() = asJsonArray

fun JsonElement?.strOrNull(): String? = if (this == null || isJsonNull) null else asString
fun JsonElement?.numOrNull(): Double? = if (this == null || isJsonNull) null else asDouble
fun JsonElement?.intOrNull(): Int? = if (this == null || isJsonNull) null else asInt
fun JsonElement?.boolOrNull(): Boolean? = if (this == null || isJsonNull) null else asBoolean

/// JsonObject.get returns null for absent keys (platform type on the JVM).
fun JsonObject.opt(key: String): JsonElement? = get(key)

fun JsonObject.keysSet(): Set<String> = keySet()

// MARK: - Check collection (mirrors the PASS/FAIL counters of the .mjs harness)

class Checks(val testName: String) {
    val failures = mutableListOf<String>()
    var passes = 0
        private set

    fun pass(label: String) {
        passes += 1
    }

    fun fail(message: String) {
        failures.add(message)
    }

    fun ok(condition: Boolean, label: String) {
        if (condition) pass(label) else fail(label)
    }

    /// Loose-typed equality the way JS === behaves over JSON values:
    /// numbers compare numerically (5 == 5.0), strings/booleans/null strictly.
    fun eq(actual: Any?, expected: Any?, label: String): Boolean {
        val equal = looseEquals(actual, expected)
        if (equal) pass(label)
        else fail("$label: expected ${render(expected)}, got ${render(actual)}")
        return equal
    }

    fun approx(actual: Double?, expected: Double, label: String, eps: Double = 1e-9) {
        if (actual != null && kotlin.math.abs(actual - expected) < eps) pass(label)
        else fail("$label: expected ~$expected, got $actual")
    }

    fun sortedEq(actual: List<String>, expected: List<String>, label: String) {
        val a = actual.sorted()
        val b = expected.sorted()
        if (a == b) pass(label)
        else fail("$label: expected $b, got $a")
    }

    /// Deep structural equality over Gson trees (object key order insensitive).
    fun deepEq(actual: JsonElement?, expected: JsonElement?, label: String) {
        val a = canonical(actual)
        val b = canonical(expected)
        if (a == b) pass(label)
        else fail("$label: expected $b, got $a")
    }

    /// Partial match: every key present in expected must match (logHead/logTail).
    fun matchesPartial(actual: JsonElement?, expected: JsonElement?, label: String) {
        if (matches(actual, expected)) pass(label)
        else fail("$label: ${render(actual)} !~ ${render(expected)}")
    }

    private fun matches(actual: JsonElement?, expected: JsonElement?): Boolean {
        if (expected == null || expected.isJsonNull) return actual == null || actual.isJsonNull
        if (expected.isJsonPrimitive) return looseEquals(toKotlin(actual), toKotlin(expected))
        if (expected.isJsonArray) {
            if (actual == null || !actual.isJsonArray) return false
            val aa = actual.asJsonArray
            val ea = expected.asJsonArray
            if (aa.size() != ea.size()) return false
            return (0 until ea.size()).all { matches(aa[it], ea[it]) }
        }
        if (expected.isJsonObject) {
            if (actual == null || !actual.isJsonObject) return false
            val ao = actual.asJsonObject
            val eo = expected.asJsonObject
            return eo.keySet().all { key -> matches(ao[key], eo[key]) }
        }
        return false
    }

    /// Flush: throw when any check failed (all failures are reported).
    fun flush() {
        if (failures.isNotEmpty()) {
            throw AssertionError(
                "$testName: ${failures.size} check(s) failed (${passes} passed):\n" +
                    failures.joinToString("\n") { "  FAIL: $it" }
            )
        }
    }

    companion object {
        fun looseEquals(actual: Any?, expected: Any?): Boolean {
            if (actual == null && expected == null) return true
            if (actual == null || expected == null) return false
            if (actual is Number && expected is Number) {
                return actual.toDouble() == expected.toDouble()
            }
            return actual == expected
        }

        /// Map a Gson element to Kotlin loose-typed values (JS semantics).
        fun toKotlin(e: JsonElement?): Any? = when {
            e == null || e.isJsonNull -> null
            e.isJsonPrimitive -> {
                val p = e.asJsonPrimitive
                when {
                    p.isBoolean -> p.asBoolean
                    p.isNumber -> {
                        val d = p.asDouble
                        // Keep integral numbers as Long for display, compare numerically anyway.
                        if (d == kotlin.math.floor(d) && !d.isInfinite()) d.toLong() else d
                    }
                    else -> p.asString
                }
            }
            else -> e
        }

        fun render(v: Any?): String = when (v) {
            null -> "null"
            is String -> "\"$v\""
            else -> v.toString()
        }

        /// Canonical JSON string with sorted object keys (key-order-insensitive compare).
        fun canonical(e: JsonElement?): String {
            val k = normalize(e)
            return Gson().toJson(k)
        }

        private fun normalize(e: JsonElement?): JsonElement? {
            if (e == null || e.isJsonNull) return null
            if (e.isJsonArray) {
                val out = JsonArray()
                e.asJsonArray.forEach { out.add(normalize(it)) }
                return out
            }
            if (e.isJsonObject) {
                val out = JsonObject()
                e.asJsonObject.keySet().sorted().forEach { k ->
                    out.add(k, normalize(e.asJsonObject[k]))
                }
                return out
            }
            return e
        }
    }
}

// MARK: - In-memory SQLite over the shared .sql migrations

class TestDb : AutoCloseable {
    val conn: Connection

    init {
        // Fresh in-memory database per fixture, exactly like the Node verifiers.
        conn = DriverManager.getConnection("jdbc:sqlite::memory:")
        conn.createStatement().use { st -> st.execute("PRAGMA foreign_keys = ON") }
    }

    /// Apply one shared migration file verbatim (byte-identical artifact with iOS).
    fun applyMigration(name: String) {
        val sql = TestDb::class.java.getResourceAsStream("/migrations/$name")
            ?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }
            ?: error("migration resource missing: $name")
        for (statement in splitStatements(sql)) {
            try {
                conn.createStatement().use { it.execute(statement) }
            } catch (e: Exception) {
                throw IllegalStateException(
                    "migration $name failed on statement <<${statement.take(400)}>>: ${e.message}", e)
            }
        }
    }

    fun applyAll(vararg names: String) {
        names.forEach { applyMigration(it) }
    }

    fun exec(sql: String) {
        conn.createStatement().use { it.execute(sql) }
    }

    /// Query returning rows as column→value maps (nulls preserved).
    fun query(sql: String, vararg params: Any?): List<Map<String, Any?>> {
        conn.prepareStatement(sql).use { ps ->
            params.forEachIndexed { i, p -> ps.setObject(i + 1, p) }
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

    fun queryOne(sql: String, vararg params: Any?): Map<String, Any?>? =
        query(sql, *params).firstOrNull()

    fun update(sql: String, vararg params: Any?): Int {
        conn.prepareStatement(sql).use { ps ->
            params.forEachIndexed { i, p -> ps.setObject(i + 1, p) }
            return ps.executeUpdate()
        }
    }

    /// INSERT with explicit column map (mirrors the .mjs `insert(db, table, row)`).
    fun insert(table: String, row: Map<String, Any?>) {
        val cols = row.keys.toList()
        val sql = "INSERT INTO $table (${cols.joinToString(", ")}) VALUES (${cols.joinToString(", ") { "?" }})"
        update(sql, *cols.map { row[it] }.toTypedArray())
    }

    fun tableNames(): List<String> =
        query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .map { it["name"] as String }

    fun tableColumns(table: String): List<Map<String, Any?>> =
        query("PRAGMA table_info(\"$table\")")

    fun sha256(text: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }

    override fun close() {
        conn.close()
    }

    companion object {
        /// Statement splitter shared with the app module's migration runner.
        /// SQLite `--` comments may contain semicolons (the shared migrations
        /// do), so comments are stripped with a string-aware scan before the
        /// split — no statement in the shared migrations contains a semicolon
        /// inside a string literal.
        fun stripComments(sql: String): String {
            val sb = StringBuilder()
            var i = 0
            var inString = false
            while (i < sql.length) {
                val c = sql[i]
                if (inString) {
                    sb.append(c)
                    if (c == '\'') {
                        if (i + 1 < sql.length && sql[i + 1] == '\'') {   // '' escape
                            sb.append('\'')
                            i += 2
                            continue
                        }
                        inString = false
                    }
                    i += 1
                    continue
                }
                if (c == '\'') {
                    inString = true
                    sb.append(c)
                    i += 1
                    continue
                }
                if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
                    while (i < sql.length && sql[i] != '\n') i += 1
                    continue   // keep the newline itself
                }
                sb.append(c)
                i += 1
            }
            return sb.toString()
        }

        fun splitStatements(sql: String): List<String> {
            return stripComments(sql).split(';')
                .map { it.trim() }
                .filter { it.isNotEmpty() }
        }
    }
}

/// The ONE canonical chain (reconciled by #32, extended by #43): unique numbers
/// 0001..0012, applied in this order by every Node verifier, every Kotlin fixture
/// runner, the Room database, and GRDB alike. 0004 is the rewritten
/// exercise-library migration (category/defaultMetric/defaultRestSec/name_normalized
/// over the real 0001 shape).
object MigrationChain {
    val FOUNDATION = arrayOf("0001_core.sql", "0002_warmup_progression.sql", "0003_import_columns.sql")
    val EXERCISES = arrayOf("0004_exercise_library.sql")
    val ROUTINES = arrayOf("0005_routines_folders.sql", "0006_routines_session_link.sql")
    val PROGRESSION = arrayOf("0007_progression_full.sql")
    val REST = arrayOf("0008_rest_fields.sql")
    val RECORDS = arrayOf("0009_personal_records.sql")
    val WARMUP = arrayOf("0010_warmup_per_exercise_toggle.sql")
    val SETTINGS = arrayOf("0011_body_metrics.sql")
    val VALIDATION = arrayOf("0012_validation_metrics.sql")

    /// Every in-chain migration, canonical order — the full chain every
    /// verifier applies (no subsets; #32).
    val ALL = FOUNDATION + EXERCISES + ROUTINES + PROGRESSION + REST + RECORDS + WARMUP + SETTINGS + VALIDATION

    /// Named aliases kept for the fixture runners: all of them now apply the
    /// FULL canonical chain in order (#32 — no verifier cherry-picks subsets).
    val PROGRESSION_FULL = ALL
    val RECORDS_FULL = ALL
    val WARMUP_FULL = ALL
    val WORKOUT_FULL = ALL
    val ANALYTICS_FULL = ALL
    val SETTINGS_FULL = ALL
}

/// ISO-8601 UTC second-precision stamp used as the deterministic "now" across
/// the seam-2 harnesses (the verifiers' `new Date().toISOString()` stand-in).
fun isoNow(): String = java.time.Instant.now().toString()
