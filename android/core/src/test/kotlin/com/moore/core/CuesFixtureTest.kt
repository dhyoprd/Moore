// SC-cues@1.0.0 fixture runner (ticket #31 Stage A).
// Kotlin mirror of Tests/MooreCuesTests/VerifyCues.mjs: the SAME 12 fixtures,
// asserted against the ported com.moore.cues.CueEngine + CueState
// (CueEngine.swift + Cue.swift 1:1, including the BR-014 gate order and the
// 64-entry FIFO ring buffer).
package com.moore.core

import com.moore.cues.CueDelivery
import com.moore.cues.CueEngine
import com.moore.cues.CueEvent
import com.moore.cues.CueName
import com.moore.cues.CueState
import com.moore.cues.DeviceContext
import com.moore.cues.ForegroundState
import com.moore.cues.HapticClass
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.moore.test.Checks
import com.moore.test.Fixtures
import com.moore.test.obj
import com.moore.test.strOrNull
import org.junit.Test

class CuesFixtureTest {

    private val fixtureNames = listOf(
        "01-taxonomy-fire-once.json",
        "02-dedupe-collapse.json",
        "03-dedupe-boundary.json",
        "04-rest-end-suppressed-post-morph.json",
        "05-rest-end-backgrounded.json",
        "06-silenced-degradation.json",
        "07-first-touch-pr-suppression.json",
        "08-precedence-one-cue-per-set.json",
        "09-drop-no-haptic.json",
        "10-confirm-blocking.json",
        "11-one-tap-accept-never-blocks.json",
        "12-ring-buffer-sequence.json",
    )

    /// Serialize a dispatch the way the fixtures spell it (cue id strings).
    private fun dispatchToJson(d: com.moore.cues.CueDispatch?): JsonElement? {
        if (d == null) return null
        val o = JsonObject()
        o.addProperty("cue", d.cue)
        o.addProperty("haptic", d.haptic?.raw)
        o.addProperty("audio", d.audio)
        o.addProperty("visual", d.visual)
        o.addProperty("blocking", d.blocking)
        o.addProperty("delivery", d.delivery.raw)
        o.addProperty("headlineKind", d.headlineKind)
        return o
    }

    private fun logEntryToJson(e: com.moore.cues.CueLogEntry): JsonElement {
        val o = JsonObject()
        o.addProperty("cue", e.cue)
        // Keep integral instants integral so canonical JSON matches the fixtures.
        if (e.at == kotlin.math.floor(e.at) && !e.at.isInfinite()) o.addProperty("at", e.at.toLong())
        else o.addProperty("at", e.at)
        o.addProperty("outcome", e.outcome.raw)
        o.addProperty("reason", e.reason)
        return o
    }

    @Test
    fun `vocabulary parity - eight cues four haptic classes closed tables`() {
        val checks = Checks("Cues.vocabulary")
        // The Kotlin channel table must carry the port-wide vocabulary (#10).
        val cueIds = listOf(
            "cue.rest.end", "cue.set.completed", "cue.set.failed", "cue.set.dropped",
            "cue.pr.achieved", "cue.pr.summary", "cue.finish.morph", "cue.confirm.destructive",
        )
        for (id in cueIds) {
            checks.ok(CueName.fromRaw(id) != null, "vocabulary.cueId.$id")
        }
        val expectedVisuals = setOf(
            "rest.over", "set.checkFill", "set.failDelta", "set.dropUndo",
            "pr.toast", "pr.cards", "finish.morph", "confirm.modal",
        )
        val visuals = CueName.allCases.map { it.channels.visual }.toSet()
        checks.eq(visuals, expectedVisuals, "vocabulary.visuals")
        for (haptic in listOf("success", "nudge", "alert", "celebration")) {
            checks.ok(HapticClass.entries.any { it.raw == haptic }, "vocabulary.hapticClass.$haptic")
        }
        for (kind in listOf("max_1rm", "max_volume", "max_reps", "max_duration")) {
            checks.ok(com.moore.cues.PRKindPrecedence.order.contains(kind), "vocabulary.prKind.$kind")
        }
        checks.flush()
    }

    @Test
    fun `all cue fixtures pass on the ported engine`() {
        val checks = Checks("Cues.fixtures")
        for (name in fixtureNames) {
            val fixture = Fixtures.json("cues", name)
            if (fixture["contractId"].strOrNull() != "SC-cues@1.0.0") {
                checks.fail("$name: contractId=${fixture["contractId"].strOrNull()} — fixtures must cite SC-cues@1.0.0")
                continue
            }
            for (vectorEl in fixture["vectors"].asJsonArray) {
                val vector = vectorEl.obj
                runVector(checks, fixture["fixture"].asString, vector)
            }
        }
        checks.flush()
    }

    private fun runVector(checks: Checks, fixtureName: String, vector: JsonObject) {
        val contextObj = vector["context"]?.takeIf { !it.isJsonNull }?.obj
        val state = CueState(
            context = if (contextObj != null) DeviceContext(
                appState = ForegroundState.fromRaw(contextObj["appState"].asString),
                silenced = contextObj["silenced"].asBoolean,
            ) else DeviceContext(),
        )
        val firedDispatches = mutableListOf<com.moore.cues.CueDispatch>()

        fun checkPending(label: String, expected: JsonElement?) {
            if (expected == null || expected.isJsonNull) return
            val want = expected.asBoolean
            if (state.pendingConfirmation == want) checks.pass("$label.pendingConfirmation=$want")
            else checks.fail("$label: pendingConfirmation=${state.pendingConfirmation} expected $want")
        }

        for ((i, stepEl) in vector["steps"].asJsonArray.withIndex()) {
            val step = stepEl.obj
            val doWhat = step["do"].asString
            val eventCue = step["event"]?.obj?.get("cue")?.strOrNull()
            val label = "$fixtureName/${vector["id"].asString}.step${i + 1}($doWhat${if (eventCue != null) ":$eventCue" else ""})"
            when (doWhat) {
                "setContext" -> {
                    val ctx = step["context"].obj
                    state.context = DeviceContext(
                        appState = ForegroundState.fromRaw(ctx["appState"].asString),
                        silenced = ctx["silenced"].asBoolean,
                    )
                    checks.pass("$label → appState=${ctx["appState"].asString} silenced=${ctx["silenced"].asBoolean}")
                }
                "resolveConfirmation" -> {
                    state.resolveConfirmation()
                    checkPending(label, step["expect"]?.obj?.get("pendingConfirmation"))
                }
                "evaluate" -> {
                    // Optional repeat expansion: `repeat` evaluations, `at` advancing
                    // by `atStep` each time (used by the ring-wrap vector).
                    val count = step["repeat"]?.asInt ?: 1
                    val atStep = step["atStep"]?.asDouble ?: 0.0
                    val baseEvent = step["event"].obj
                    for (k in 0 until count) {
                        val at = baseEvent["at"].asDouble + k * atStep
                        val event = CueEvent(
                            nameRaw = baseEvent["cue"].asString,
                            at = at,
                            setId = baseEvent["setId"].strOrNull(),
                            beatenKinds = baseEvent["beatenKinds"]?.takeIf { it.isJsonArray }
                                ?.asJsonArray?.map { it.asString },
                        )
                        val before = state.totalEntries
                        val dispatches = CueEngine.evaluate(event, state)
                        val entry = state.log.last()
                        if (state.totalEntries != before + 1) {
                            checks.fail("$label[$k]: evaluation appended no log entry (BR-013 violated)")
                            continue
                        }
                        val ex = step["expect"]?.takeIf { !it.isJsonNull }?.obj
                        var ok = true
                        if (ex != null && ex.has("outcome") && entry.outcome.raw != ex["outcome"].asString) {
                            ok = false
                            checks.fail("$label[$k]: outcome=${entry.outcome.raw} expected ${ex["outcome"].asString}")
                        }
                        val expectedReason = ex?.get("reason")?.strOrNull()
                        if (ok && ex != null && ex.has("reason") && entry.reason != expectedReason) {
                            ok = false
                            checks.fail("$label[$k]: reason=${entry.reason} expected $expectedReason")
                        }
                        if (ok && entry.outcome == com.moore.cues.CueOutcome.FIRED && dispatches.size != 1) {
                            ok = false
                            checks.fail("$label[$k]: fired but ${dispatches.size} dispatches")
                        }
                        if (ok && entry.outcome != com.moore.cues.CueOutcome.FIRED && dispatches.isNotEmpty()) {
                            ok = false
                            checks.fail("$label[$k]: ${entry.outcome.raw} but ${dispatches.size} dispatches")
                        }
                        if (ok && ex != null && ex.has("dispatch")) {
                            val expectedDispatch = ex["dispatch"]
                            val matches = Checks.canonical(dispatchToJson(dispatches.firstOrNull())) ==
                                Checks.canonical(expectedDispatch)
                            if (!matches) {
                                ok = false
                                checks.fail("$label[$k]: dispatch ${dispatchToJson(dispatches.firstOrNull())} != expected $expectedDispatch")
                            }
                        }
                        if (ok) {
                            if (count > 1) {
                                if (k == 0 || k == count - 1) checks.pass("$label[$k]")
                            } else checks.pass(label)
                        }
                        if (entry.outcome == com.moore.cues.CueOutcome.FIRED) {
                            firedDispatches.add(dispatches[0])
                        }
                        checkPending("$label[$k]", ex?.get("pendingConfirmation"))
                    }
                }
                else -> checks.fail("$label: unknown step type $doWhat")
            }
        }

        val fin = vector["finalExpect"]?.takeIf { !it.isJsonNull }?.obj ?: JsonObject()
        val vid = "$fixtureName/${vector["id"].asString}.final"
        if (fin.has("dispatchCount")) {
            val want = fin["dispatchCount"].asInt
            if (firedDispatches.size == want) checks.pass("$vid.dispatchCount=$want")
            else checks.fail("$vid: dispatchCount=${firedDispatches.size} expected $want")
        }
        if (fin.has("firedCues")) {
            val got = firedDispatches.map { it.cue }
            val want = fin["firedCues"].asJsonArray.map { it.asString }
            if (got == want) checks.pass("$vid.firedCues")
            else checks.fail("$vid: firedCues=$got expected $want")
        }
        if (fin.has("noBlockingEver") && fin["noBlockingEver"].asBoolean) {
            val blockers = firedDispatches.filter { it.blocking }
            if (blockers.isEmpty()) checks.pass("$vid.noBlockingEver")
            else checks.fail("$vid: ${blockers.size} blocking dispatch(es) on the accept path (BR-011 violated)")
        }
        if (fin.has("log")) {
            val got = com.google.gson.JsonArray().also { arr -> state.log.forEach { arr.add(logEntryToJson(it)) } }
            if (Checks.canonical(got) == Checks.canonical(fin["log"])) checks.pass("$vid.log")
            else checks.fail("$vid: log $got != expected ${fin["log"]}")
        }
        if (fin.has("logLength")) {
            val want = fin["logLength"].asInt
            if (state.log.size == want) checks.pass("$vid.logLength=$want")
            else checks.fail("$vid: logLength=${state.log.size} expected $want")
        }
        if (fin.has("logHead")) {
            val head = state.log.firstOrNull()?.let { logEntryToJson(it) }
            if (matchesPartialJson(head, fin["logHead"])) checks.pass("$vid.logHead")
            else checks.fail("$vid: logHead $head !~ ${fin["logHead"]}")
        }
        if (fin.has("logTail")) {
            val tail = state.log.lastOrNull()?.let { logEntryToJson(it) }
            if (matchesPartialJson(tail, fin["logTail"])) checks.pass("$vid.logTail")
            else checks.fail("$vid: logTail $tail !~ ${fin["logTail"]}")
        }
        if (fin.has("overlayMorphedToFinish")) {
            val want = fin["overlayMorphedToFinish"].asBoolean
            if (state.overlayMorphedToFinish == want) checks.pass("$vid.overlayMorphedToFinish=$want")
            else checks.fail("$vid: overlayMorphedToFinish=${state.overlayMorphedToFinish} expected $want")
        }
        if (fin.has("pendingConfirmation")) {
            val want = fin["pendingConfirmation"].asBoolean
            if (state.pendingConfirmation == want) checks.pass("$vid.pendingConfirmation=$want")
            else checks.fail("$vid: pendingConfirmation=${state.pendingConfirmation} expected $want")
        }
    }

    private fun matchesPartialJson(actual: JsonElement?, expected: JsonElement?): Boolean {
        if (expected == null || expected.isJsonNull) return actual == null || actual?.isJsonNull == true
        if (expected.isJsonPrimitive) return Checks.looseEquals(Checks.toKotlin(actual), Checks.toKotlin(expected))
        if (expected.isJsonArray) {
            if (actual == null || !actual.isJsonArray) return false
            val aa = actual.asJsonArray
            val ea = expected.asJsonArray
            if (aa.size() != ea.size()) return false
            return (0 until ea.size()).all { matchesPartialJson(aa[it], ea[it]) }
        }
        if (expected.isJsonObject) {
            if (actual == null || !actual.isJsonObject) return false
            val ao = actual.asJsonObject
            val eo = expected.asJsonObject
            return eo.keySet().all { key -> matchesPartialJson(ao.get(key), eo[key]) }
        }
        return false
    }
}
