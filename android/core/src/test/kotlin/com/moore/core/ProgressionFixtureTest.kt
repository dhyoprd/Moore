// SC-progression@1.0.0 fixture runner (ticket #31 Stage A).
// Kotlin mirror of Tests/MooreProgressionTests/VerifyProgression.mjs: the SAME
// fixtures/schemes.json + stalls.json vectors, asserted against the ported
// com.moore.progression.ProgressionEngine (ProgressionEngine.swift 1:1).
package com.moore.core

import com.moore.progression.ExerciseMetric
import com.moore.progression.ProgressionEngine
import com.moore.progression.ProgressionRecord
import com.moore.progression.ReferenceSessionSet
import com.moore.progression.Scheme
import com.moore.progression.StallAction
import com.moore.foundation.SetStatus
import com.moore.test.Checks
import com.moore.test.Fixtures
import com.moore.test.MigrationChain
import com.moore.test.TestDb
import com.moore.test.boolOrNull
import com.moore.test.intOrNull
import com.moore.test.numOrNull
import com.moore.test.obj
import com.moore.test.strOrNull
import org.junit.Test

class ProgressionFixtureTest {

    private fun parseRecord(rec: com.google.gson.JsonObject): ProgressionRecord {
        return ProgressionRecord(
            id = rec["id"].strOrNull() ?: "",
            routineId = rec["routineId"].strOrNull() ?: "",
            exerciseId = rec["exerciseId"].strOrNull() ?: "",
            scheme = rec["scheme"]?.strOrNull()?.let { Scheme.fromRaw(it) } ?: Scheme.NONE,
            stallCount = rec["stallCount"]?.intOrNull() ?: 0,
            stallMuted = (rec["stallMuted"]?.intOrNull() ?: 0) != 0,
            nextBannerAt = rec["nextBannerAt"]?.intOrNull() ?: 3,
            deloadPending = (rec["deloadPending"]?.intOrNull() ?: 0) != 0,
            lastDeloadSessionId = rec["lastDeloadSessionId"].strOrNull(),
            stalledWeight = rec["stalledWeight"].numOrNull(),
            stalledReps = rec["stalledReps"].intOrNull(),
            stalledDurationSec = rec["stalledDurationSec"].intOrNull(),
            baselineDurationSec = rec["baselineDurationSec"].intOrNull(),
        )
    }

    private fun parseReferenceSets(arr: com.google.gson.JsonArray): List<ReferenceSessionSet> {
        return arr.map { el ->
            val o = el.obj
            ReferenceSessionSet(
                sessionId = o["sessionId"].strOrNull() ?: "",
                routineId = o["routineId"].strOrNull(),
                status = SetStatus.fromRaw(o["status"].strOrNull() ?: "planned"),
                exerciseId = o["exerciseId"].strOrNull() ?: "",
                setOrdinal = o["setOrdinal"]?.intOrNull() ?: 0,
                plannedWeight = o["plannedWeight"].numOrNull(),
                plannedReps = o["plannedReps"].intOrNull(),
                plannedDuration = o["plannedDuration"].intOrNull(),
                actualWeight = o["actualWeight"].numOrNull(),
                actualReps = o["actualReps"].intOrNull(),
                actualDuration = o["actualDuration"].intOrNull(),
            )
        }
    }

    private fun recordField(rec: ProgressionRecord, key: String): Any? = when (key) {
        "stallCount" -> rec.stallCount
        "stallMuted" -> if (rec.stallMuted) 1 else 0
        "nextBannerAt" -> rec.nextBannerAt
        "deloadPending" -> if (rec.deloadPending) 1 else 0
        "lastDeloadSessionId" -> rec.lastDeloadSessionId
        "stalledWeight" -> rec.stalledWeight
        "stalledReps" -> rec.stalledReps
        "stalledDurationSec" -> rec.stalledDurationSec
        "baselineDurationSec" -> rec.baselineDurationSec
        else -> error("unknown rec field $key")
    }

    @Test
    fun `schema - progression_scheme post-0007 shape matches contract section 2`() {
        val checks = Checks("Progression.schema")
        TestDb().use { db ->
            db.applyAll(*MigrationChain.PROGRESSION_FULL)
            val cols = db.tableColumns("progression_scheme").map { it["name"] as String }
            for (c in listOf("nextBannerAt", "deloadPending", "stalledWeight", "stalledReps",
                "stalledDurationSec", "baselineDurationSec")) {
                checks.ok(c in cols, "schema.progression_scheme.$c")
            }
            checks.flush()
        }
    }

    @Test
    fun `fixture vectors pass against the ported engine`() {
        val checks = Checks("Progression.fixtures")
        for (fname in listOf("schemes.json", "stalls.json")) {
            val fx = Fixtures.json("progression", fname)
            for (vEl in fx["vectors"]!!.asJsonArray) {
                val v = vEl.obj
                val id = "$fname.${v["id"].strOrNull()}"
                val rec = parseRecord(v["rec"].obj)
                val metric = if (v["metric"].strOrNull() == "duration") ExerciseMetric.DURATION else ExerciseMetric.REPS
                val category = v["category"].strOrNull()
                val blueprint = v["blueprint"]?.takeIf { it.isJsonObject }?.obj
                val reference = v["reference"]?.takeIf { it.isJsonArray }?.let { parseReferenceSets(it.asJsonArray) }

                // ---- Suggest path (mjs runs it for every vector) ----
                val out = ProgressionEngine.suggest(
                    record = rec,
                    reference = reference,
                    metric = metric,
                    category = category,
                    blueprintWeight = blueprint?.get("weight").numOrNull(),
                    blueprintReps = blueprint?.get("reps").intOrNull(),
                    blueprintDurationSec = blueprint?.get("durationSec").intOrNull(),
                )
                val expect = v["expect"]?.takeIf { it.isJsonObject }?.obj
                if (expect != null) {
                    if (expect.has("weight")) checks.eq(out.suggestion.weight, expect["weight"].numOrNull(), "$id.weight")
                    if (expect.has("reps")) checks.eq(out.suggestion.reps, expect["reps"].intOrNull(), "$id.reps")
                    if (expect.has("durationSec")) checks.eq(out.suggestion.durationSec, expect["durationSec"].intOrNull(), "$id.durationSec")
                    val touchedExpected = expect["touched"]?.takeIf { it.isJsonArray }?.asJsonArray?.map { it.asString }
                    if (touchedExpected != null) checks.eq(out.suggestion.touched, touchedExpected, "$id.touched")
                }

                // ---- Stall lifecycle (onSessionFinished) ----
                val stall = v["stall"]?.takeIf { it.isJsonObject }?.obj
                if (stall != null) {
                    val currentSets = v["currentSets"]?.takeIf { it.isJsonArray }
                        ?.let { parseReferenceSets(it.asJsonArray) } ?: emptyList()
                    val previousWeight = v["previousWeight"].numOrNull()
                    val r = ProgressionEngine.onSessionFinished(
                        record = rec,
                        currentSessionSets = currentSets,
                        previousWorkingWeight = previousWeight,
                        metric = metric,
                        exerciseName = "EX",
                    )
                    if (stall.has("banner")) checks.eq(r.shouldBanner, stall["banner"].boolOrNull(), "$id.stall.banner")
                    val copyMatch = stall["copyMatch"].strOrNull()
                    if (copyMatch != null) {
                        val matched = Regex(copyMatch).containsMatchIn(r.bannerCopy ?: "")
                        checks.ok(matched, "$id.stall.copyMatch (copy=${r.bannerCopy})")
                    }
                    val recExpect = stall["rec"]?.takeIf { it.isJsonObject }?.obj
                    if (recExpect != null) {
                        for (k in recExpect.keySet()) {
                            checks.eq(recordField(r.updatedRecord, k), Checks.toKotlin(recExpect[k]), "$id.stall.rec.$k")
                        }
                    }
                }

                // ---- Stall-choice application ----
                val stallAction = v["stallAction"]?.strOrNull()
                if (stallAction != null) {
                    val args = v["stallActionArgs"]?.takeIf { it.isJsonObject }?.obj
                    val r = ProgressionEngine.applyStallChoice(
                        action = StallAction.fromRaw(stallAction),
                        record = rec,
                        currentWeight = args?.get("weight").numOrNull(),
                        currentReps = args?.get("reps").intOrNull(),
                        currentDurationSec = args?.get("durationSec").intOrNull(),
                    )
                    val stallExpect = v["stallExpect"]?.takeIf { it.isJsonObject }?.obj
                    if (stallExpect != null) {
                        for (k in stallExpect.keySet()) {
                            checks.eq(recordField(r, k), Checks.toKotlin(stallExpect[k]), "$id.stallAction.$k")
                        }
                    }
                }
            }
        }
        checks.flush()
    }
}
