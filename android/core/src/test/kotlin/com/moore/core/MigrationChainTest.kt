// MigrationChainTest (ticket #31 Stage A).
// Applies EVERY shared .sql migration in the canonical chain order to an
// in-memory sqlite-jdbc database and asserts the resulting table shapes —
// the byte-identical-artifact AC: the same files iOS applies via GRDB apply
// verbatim on Android and produce the same schema.
//
// Chain order (Node-verifier order; 0004 excluded per docs/MIGRATION-INTEGRATION-NOTE.md):
//   0001_core, 0002_warmup_progression, 0003_import_columns,
//   0005_routines_folders, 0006_routines_session_link,
//   0007_progression_full, 0007_rest_fields,
//   0008_personal_records, 0008_warmup_per_exercise_toggle,
//   0009_body_metrics
package com.moore.core

import com.moore.test.Checks
import com.moore.test.MigrationChain
import com.moore.test.TestDb
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class MigrationChainTest {

    private fun columns(db: TestDb, table: String): List<String> =
        db.tableColumns(table).map { it["name"] as String }

    @Test
    fun `migration chain applies in order and produces the canonical schema`() {
        val checks = Checks("MigrationChain")
        TestDb().use { db ->
            // Every migration applies cleanly, in order, against the prior state.
            for (name in MigrationChain.ALL) {
                try {
                    db.applyMigration(name)
                    checks.pass("migration.apply $name")
                } catch (e: Exception) {
                    checks.fail("migration.apply $name: ${e.message}")
                }
            }

            // Canonical tables present post-chain.
            val tables = db.tableNames()
            val expected = listOf(
                "app_setting",
                "body_metric",
                "completed_set",
                "exercise",
                "folder",
                "personal_record",
                "planned_set",
                "progression_scheme",
                "routine",
                "warmup_contract_scaffold",
                "workout_session",
            )
            for (t in expected) {
                checks.ok(t in tables, "table.$t.exists")
            }
            // Legacy tables preserved by the rebuild migrations (INV-ST3 / 0008 precedent).
            for (t in listOf("progression_scheme__legacy_0002", "personal_record__legacy_0001", "body_metric__legacy_0001")) {
                checks.ok(t in tables, "table.$t.preserved")
            }

            // Table shapes: exact column sets (camelCase per SC-foundation §3).
            checks.eq(columns(db, "folder"),
                listOf("id", "name", "createdAt", "updatedAt", "deletedAt"), "shape.folder")
            checks.eq(columns(db, "exercise"),
                listOf("id", "name", "exerciseType", "equipmentSlug", "primaryMuscleId",
                    "secondaryMuscleIdsJson", "instructions", "isCustom",
                    "createdAt", "updatedAt", "deletedAt"), "shape.exercise")
            checks.eq(columns(db, "routine"),
                listOf("id", "folderId", "name", "sortOrder", "createdAt", "updatedAt", "deletedAt", "restSec"),
                "shape.routine")
            checks.eq(columns(db, "planned_set"),
                listOf("id", "routineId", "exerciseId", "sortOrder", "plannedWeight", "plannedReps",
                    "plannedDuration", "createdAt", "updatedAt", "deletedAt", "setClass", "restDurationSec"),
                "shape.planned_set")
            checks.eq(columns(db, "workout_session"),
                listOf("id", "startedAt", "endedAt", "createdAt", "updatedAt", "deletedAt",
                    "name", "notes", "importSource", "importKey", "routineId"),
                "shape.workout_session")
            checks.eq(columns(db, "completed_set"),
                listOf("id", "sessionId", "exerciseId", "sortOrder", "plannedWeight", "plannedReps",
                    "plannedDuration", "actualWeight", "actualReps", "actualDuration", "status",
                    "completedAt", "createdAt", "updatedAt", "deletedAt", "setClass"),
                "shape.completed_set")
            // Post-0008 canonical personal_record (sessionId + widened kind).
            checks.eq(columns(db, "personal_record"),
                listOf("id", "exerciseId", "sessionId", "setId", "kind", "value", "achievedAt",
                    "createdAt", "updatedAt", "deletedAt"),
                "shape.personal_record")
            // Post-0009 canonical body_metric (label column).
            checks.eq(columns(db, "body_metric"),
                listOf("id", "kind", "label", "value", "unit", "recordedAt",
                    "createdAt", "updatedAt", "deletedAt"),
                "shape.body_metric")
            // Post-0007_progression_full canonical progression_scheme.
            checks.eq(columns(db, "progression_scheme"),
                listOf("id", "routineId", "exerciseId", "scheme", "incrementValue",
                    "doubleProgressionMinReps", "doubleProgressionMaxReps", "warmupEnabled",
                    "stallCount", "stallMuted", "nextBannerAt", "deloadPending",
                    "lastDeloadSessionId", "stalledWeight", "stalledReps",
                    "stalledDurationSec", "baselineDurationSec", "createdAt", "updatedAt", "deletedAt"),
                "shape.progression_scheme")
            checks.eq(columns(db, "app_setting"),
                listOf("key", "value", "updatedAt"), "shape.app_setting")
            checks.eq(columns(db, "warmup_contract_scaffold"),
                listOf("id", "contractId", "version", "createdAt", "updatedAt", "deletedAt"),
                "shape.warmup_contract_scaffold")

            // INV-S2: the 0007 seed installed the two rest defaults.
            val compound = db.queryOne("SELECT value FROM app_setting WHERE key = 'defaultRestCompoundSec'")
            val isolation = db.queryOne("SELECT value FROM app_setting WHERE key = 'defaultRestIsolationSec'")
            checks.eq(compound?.get("value"), "180", "seed.defaultRestCompoundSec")
            checks.eq(isolation?.get("value"), "90", "seed.defaultRestIsolationSec")

            // CHECK vocabulary healed by the rebuild migrations.
            db.insert("exercise", mapOf(
                "id" to "ex-x", "name" to "X", "exerciseType" to "strength", "isCustom" to 0,
                "createdAt" to "t", "updatedAt" to "t"))
            db.insert("workout_session", mapOf(
                "id" to "s-x", "startedAt" to "t", "createdAt" to "t", "updatedAt" to "t"))

            // personal_record: post-0008 kinds accepted, legacy kind rejected.
            db.insert("personal_record", mapOf(
                "id" to "p-ok", "exerciseId" to "ex-x", "sessionId" to "s-x", "kind" to "max_duration",
                "value" to 90.0, "achievedAt" to "t", "createdAt" to "t", "updatedAt" to "t"))
            checks.pass("check.personal_record.max_duration.accepted")
            val badKind = try {
                db.insert("personal_record", mapOf(
                    "id" to "p-bad", "exerciseId" to "ex-x", "sessionId" to "s-x", "kind" to "weight",
                    "value" to 1.0, "achievedAt" to "t", "createdAt" to "t", "updatedAt" to "t"))
                false
            } catch (e: Exception) {
                true
            }
            checks.ok(badKind, "check.personal_record.legacy-kind-rejected")

            // body_metric: measurement accepted post-0009, legacy weight rejected.
            db.insert("body_metric", mapOf(
                "id" to "bm-ok", "kind" to "measurement", "label" to "Waist", "value" to 84.0,
                "unit" to "cm", "recordedAt" to "t", "createdAt" to "t", "updatedAt" to "t"))
            checks.pass("check.body_metric.measurement.accepted")
            val badMetric = try {
                db.insert("body_metric", mapOf(
                    "id" to "bm-bad", "kind" to "weight", "value" to 80.0, "unit" to "kg",
                    "recordedAt" to "t", "createdAt" to "t", "updatedAt" to "t"))
                false
            } catch (e: Exception) {
                true
            }
            checks.ok(badMetric, "check.body_metric.legacy-kind-rejected")

            // progression_scheme: widened scheme vocabulary, percentage removed.
            db.insert("routine", mapOf(
                "id" to "r-x", "name" to "R", "sortOrder" to 0, "createdAt" to "t", "updatedAt" to "t"))
            db.insert("progression_scheme", mapOf(
                "id" to "ps-ok", "routineId" to "r-x", "exerciseId" to "ex-x", "scheme" to "hold-duration",
                "createdAt" to "t", "updatedAt" to "t"))
            checks.pass("check.progression_scheme.hold-duration.accepted")
            val badScheme = try {
                db.insert("progression_scheme", mapOf(
                    "id" to "ps-bad", "routineId" to "r-x", "exerciseId" to "ex-x", "scheme" to "percentage",
                    "createdAt" to "t", "updatedAt" to "t"))
                false
            } catch (e: Exception) {
                true
            }
            checks.ok(badScheme, "check.progression_scheme.percentage-rejected")

            // completed_set status vocabulary (SC-foundation 0001).
            val badStatus = try {
                db.insert("completed_set", mapOf(
                    "id" to "cs-bad", "sessionId" to "s-x", "exerciseId" to "ex-x", "sortOrder" to 0,
                    "status" to "resting", "createdAt" to "t", "updatedAt" to "t"))
                false
            } catch (e: Exception) {
                true
            }
            checks.ok(badStatus, "check.completed_set.status-vocabulary")

            // BR-007 importKey UNIQUE partial index: duplicates rejected, NULLs never collide.
            db.insert("workout_session", mapOf(
                "id" to "s-imp1", "startedAt" to "2025-01-01T00:00:00Z", "importSource" to "hevy",
                "importKey" to "k|2025-01-01T00:00:00Z", "createdAt" to "t", "updatedAt" to "t"))
            val dupRejected = try {
                db.insert("workout_session", mapOf(
                    "id" to "s-imp2", "startedAt" to "2025-01-01T00:00:00Z", "importSource" to "hevy",
                    "importKey" to "k|2025-01-01T00:00:00Z", "createdAt" to "t", "updatedAt" to "t"))
                false
            } catch (e: Exception) {
                true
            }
            checks.ok(dupRejected, "check.importKey.unique-dedupe (BR-007)")
            db.insert("workout_session", mapOf(
                "id" to "s-null1", "startedAt" to "2025-01-02T00:00:00Z", "createdAt" to "t", "updatedAt" to "t"))
            db.insert("workout_session", mapOf(
                "id" to "s-null2", "startedAt" to "2025-01-03T00:00:00Z", "createdAt" to "t", "updatedAt" to "t"))
            checks.pass("check.importKey.null-never-collides")

            // 0008_warmup shape-assertion marker (setClass + warmupEnabled confirmed present).
            val marker = db.queryOne(
                "SELECT id FROM warmup_contract_scaffold WHERE id = 'sc-warmup-1.0.0-shape-check'")
            checks.ok(marker != null, "migration.0008.shape-assertion-marker")

            checks.flush()
        }
    }

    @Test
    fun `0004 exercise library stays out of the chain pending rewrite`() {
        // docs/MIGRATION-INTEGRATION-NOTE.md: 0004 targets the assumed #19 shape
        // (snake_case + category) and MUST be rewritten before it applies over
        // 0001. Every Node verifier skips it; the Android chain does the same.
        TestDb().use { db ->
            db.applyAll(*MigrationChain.FOUNDATION)
            val failsOverRealChain = try {
                db.applyMigration("0004_exercise_library.sql")
                false
            } catch (e: Exception) {
                true
            }
            assertTrue(
                "0004 must not apply over the real 0001 shape until rewritten",
                failsOverRealChain,
            )
        }
    }
}
