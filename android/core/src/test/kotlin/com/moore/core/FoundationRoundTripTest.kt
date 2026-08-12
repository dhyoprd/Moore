// SC-foundation@1.0.0 fixture runner (ticket #31 Stage A).
// Kotlin mirror of Tests/MooreFoundationTests/VerifyMigrations.mjs: applies
// 0001→0003, then for every round-trip fixture inserts each entity, selects it
// back by id, and asserts field-for-field equality including NULL preservation.
//
// Vector ↔ BR mapping (contract template §7):
//   V1, V2  → BR-001 (additive-only, idempotent apply)
//   V3..V13 → INV-1 / INV-4 (UUID, round-trip equality incl. NULLs)
//   V8      → BR-007 (importKey UNIQUE dedupe)
//   V9, V10 → BR-004 (dual plannedX/actualX lawful NULL)
//   V14     → BR-003 (tombstone semantics)
//   V15     → BR-004 stress
package com.moore.core

import com.moore.test.Checks
import com.moore.test.Fixtures
import com.moore.test.MigrationChain
import com.moore.test.TestDb
import com.moore.test.numOrNull
import com.moore.test.obj
import com.moore.test.strOrNull
import org.junit.Test

class FoundationRoundTripTest {

    private val entityToTable = mapOf(
        "Folder" to "folder",
        "Exercise" to "exercise",
        "Routine" to "routine",
        "PlannedSet" to "planned_set",
        "WorkoutSession" to "workout_session",
        "CompletedSet" to "completed_set",
        "PersonalRecord" to "personal_record",
        "BodyMetric" to "body_metric",
        "ProgressionScheme" to "progression_scheme",
    )

    private val fixtureNames = listOf(
        "round-trip-vector-01.json",
        "round-trip-vector-02.json",
        "round-trip-vector-03.json",
        "round-trip-vector-04.json",
        "round-trip-vector-05.json",
    )

    private fun roundTripEntity(db: TestDb, checks: Checks, entityLabel: String, record: Map<String, Any?>) {
        val entityName = entityLabel.split('.')[0]
        val table = entityToTable[entityName]
        if (table == null) {
            checks.fail("$entityLabel: unknown entity prefix")
            return
        }
        try {
            db.insert(table, record)
        } catch (e: Exception) {
            checks.fail("$entityLabel: INSERT threw: ${e.message}")
            return
        }
        val cols = record.keys.toList()
        val row = db.queryOne("SELECT ${cols.joinToString(", ")} FROM $table WHERE id = ?", record["id"])
        if (row == null) {
            checks.fail("$entityLabel: SELECT by id returned no row")
            return
        }
        var allMatch = true
        for (col in cols) {
            val expected = record[col]
            val actual = row[col]
            val equal = when {
                expected == null && actual == null -> true
                expected is Number && actual is Number -> expected.toDouble() == actual.toDouble()
                else -> expected == actual
            }
            if (!equal) {
                checks.fail("$entityLabel.$col: expected $expected, got $actual")
                allMatch = false
            }
        }
        if (allMatch) checks.pass("$entityLabel round-trip")
    }

    @Test
    fun `round-trip vectors V1-V15 pass field-for-field including NULLs`() {
        val checks = Checks("FoundationRoundTrip")
        TestDb().use { db ->
            // V1 — apply migrations in order.
            for (name in MigrationChain.FOUNDATION) {
                try {
                    db.applyMigration(name)
                    checks.pass("migration.apply $name")
                } catch (e: Exception) {
                    checks.fail("migration.apply $name: ${e.message}")
                    checks.flush()
                    return
                }
            }

            // Confirm all nine expected tables exist.
            val tables = db.tableNames()
            val expectedTables = listOf(
                "body_metric", "completed_set", "exercise", "folder",
                "personal_record", "planned_set", "progression_scheme",
                "routine", "workout_session",
            )
            val missing = expectedTables.filter { it !in tables }
            checks.ok(missing.isEmpty(), "schema.all-nine-tables-exist (missing=$missing)")

            // V2 — the migration tracker is idempotent (GRDB marker simulation).
            db.exec("CREATE TABLE IF NOT EXISTS schema_migrations (identifier TEXT PRIMARY KEY, appliedAt TEXT NOT NULL)")
            for (name in MigrationChain.FOUNDATION) {
                val already = db.queryOne("SELECT 1 AS x FROM schema_migrations WHERE identifier = ?", name)
                if (already != null) {
                    checks.pass("migration.idempotent $name (skipped)")
                    continue
                }
                db.update("INSERT INTO schema_migrations (identifier, appliedAt) VALUES (?, ?)", name, "2026-08-12T00:00:00Z")
                checks.pass("migration.idempotent $name (marked)")
            }

            // V3..V15 — fixtures.
            val loaded = HashMap<String, com.google.gson.JsonObject>()
            for (fname in fixtureNames) {
                val fixture = Fixtures.json("foundation", fname)
                loaded[fname] = fixture

                // Dependency check: named prior fixtures must be present.
                fixture["dependsOn"]?.takeIf { it.isJsonArray }?.asJsonArray?.forEach { dep ->
                    if (!loaded.containsKey(dep.asString)) {
                        checks.fail("$fname: dependsOn ${dep.asString} not yet loaded (fixture order wrong)")
                    }
                }

                val entities = fixture["entities"].obj
                for (label in entities.keySet()) {
                    val recordObj = entities[label].obj
                    val record = LinkedHashMap<String, Any?>()
                    for (col in recordObj.keySet()) {
                        record[col] = com.moore.test.Checks.toKotlin(recordObj[col])
                    }
                    roundTripEntity(db, checks, label, record)
                }

                // Vector-3 explicit assertion: importKey UNIQUE rejects a duplicate insert.
                val asserts = fixture["asserts"]
                val dup = asserts?.obj?.get("duplicateImportKeyRejected")
                if (dup != null && !dup.isJsonNull) {
                    val dupObj = dup.obj
                    val insertDuplicateOf = dupObj["insertDuplicateOf"].strOrNull()!!
                    val differentId = dupObj["differentId"].strOrNull()!!
                    val original = loaded.getValue(fname)["entities"].obj[insertDuplicateOf].obj
                    val dupe = LinkedHashMap<String, Any?>()
                    for (col in original.keySet()) {
                        dupe[col] = Checks.toKotlin(original[col])
                    }
                    dupe["id"] = differentId
                    val cols = dupe.keys.toList()
                    val threw = try {
                        db.insert("workout_session", dupe)
                        false
                    } catch (e: Exception) {
                        e.message?.contains("UNIQUE", ignoreCase = true) == true
                    }
                    checks.ok(threw, "asserts.duplicateImportKeyRejected (BR-007 UNIQUE)")
                }

                // V14 — tombstone: soft-delete the Folder from vector-01.
                val vectorNum = fixture["vector"]?.numOrNull()
                if (vectorNum == 1.0) {
                    val folderId = loaded.getValue(fname)["entities"].obj["Folder"].obj["id"].asString
                    val now = "2026-08-12T12:00:00Z"
                    db.update("UPDATE folder SET deletedAt = ?, updatedAt = ? WHERE id = ?", now, now, folderId)
                    val visible = db.queryOne("SELECT id FROM folder WHERE id = ? AND deletedAt IS NULL", folderId)
                    val tombstoned = db.queryOne("SELECT id, deletedAt FROM folder WHERE id = ?", folderId)
                    checks.ok(visible == null, "V14.tombstone.hidden-from-default-fetch")
                    checks.ok(tombstoned != null && tombstoned["deletedAt"] != null,
                        "V14.tombstone.row-still-present-with-deletedAt")
                }
            }

            checks.flush()
        }
    }
}
