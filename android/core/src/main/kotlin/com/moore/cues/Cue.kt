// contractId: SC-cues @1.0.0
// The cue vocabulary (§3) — eight cue IDs, four haptic classes, the
// cue→channel mapping table (#10 taxonomy, verbatim), device context, and the
// PR-kind precedence helper (BR-008 headline rule). Port-wide vocabulary:
// code cites "cue.rest.end", never a local name (#10 downstream ruling).
// Mechanical Kotlin port of Sources/MooreCues/Cue.swift. Pure JVM, no Android imports.
package com.moore.cues

/// §3 CueName — the eight cues of v1, addressed by ID. Raw values are the
/// port-wide cue IDs. INV-C7: unknown/forward-compat ids never construct a
/// case (`fromRaw` returns null) and are suppressed upstream, never a crash.
enum class CueName(val raw: String) {
    REST_END("cue.rest.end"),
    SET_COMPLETED("cue.set.completed"),
    SET_FAILED("cue.set.failed"),
    SET_DROPPED("cue.set.dropped"),
    PR_ACHIEVED("cue.pr.achieved"),
    PR_SUMMARY("cue.pr.summary"),
    FINISH_MORPH("cue.finish.morph"),
    CONFIRM_DESTRUCTIVE("cue.confirm.destructive");

    /// The §3(a) table, in code. One row per cue; the JS mirror and the
    /// fixtures assert byte-parity against this table (VerifyCues.mjs).
    val channels: CueChannelSet
        get() = when (this) {
            REST_END -> CueChannelSet(
                haptic = HapticClass.ALERT, audio = true, visual = "rest.over",
                firesSilenced = true, firesBackgroundedOrLocked = true, blocking = false)
            SET_COMPLETED -> CueChannelSet(
                haptic = HapticClass.SUCCESS, audio = false, visual = "set.checkFill",
                firesSilenced = true, firesBackgroundedOrLocked = false, blocking = false)
            SET_FAILED -> CueChannelSet(
                haptic = HapticClass.NUDGE, audio = false, visual = "set.failDelta",
                firesSilenced = true, firesBackgroundedOrLocked = false, blocking = false)
            // BR-009: a drop has NO haptic — the undo toolbar is the cue.
            SET_DROPPED -> CueChannelSet(
                haptic = null, audio = false, visual = "set.dropUndo",
                firesSilenced = true, firesBackgroundedOrLocked = false, blocking = false)
            PR_ACHIEVED -> CueChannelSet(
                haptic = HapticClass.CELEBRATION, audio = false, visual = "pr.toast",
                firesSilenced = true, firesBackgroundedOrLocked = false, blocking = false)
            PR_SUMMARY -> CueChannelSet(
                haptic = null, audio = false, visual = "pr.cards",
                firesSilenced = true, firesBackgroundedOrLocked = false, blocking = false)
            FINISH_MORPH -> CueChannelSet(
                haptic = null, audio = false, visual = "finish.morph",
                firesSilenced = true, firesBackgroundedOrLocked = false, blocking = false)
            // INV-C5: the only blocking cue in v1 (BR-010). No haptic.
            CONFIRM_DESTRUCTIVE -> CueChannelSet(
                haptic = null, audio = false, visual = "confirm.modal",
                firesSilenced = true, firesBackgroundedOrLocked = false, blocking = true)
        }

    companion object {
        val allCases: List<CueName> get() = entries
        fun fromRaw(raw: String): CueName? = entries.firstOrNull { it.raw == raw }
    }
}

/// §3b HapticClass — the four haptic characters (#10, verbatim).
enum class HapticClass(val raw: String) {
    /// Single light tick — "logged".
    SUCCESS("success"),
    /// Single medium tap — "attention warranted, nothing wrong".
    NUDGE("nudge"),
    /// Repeated urgent pattern — "return to work now".
    ALERT("alert"),
    /// Distinct multi-stage pattern — "achievement"; exactly one cue per set.
    CELEBRATION("celebration");
}

/// Foreground axis of DeviceContext. Backgrounded and locked are one bucket:
/// the cue contract cares only whether in-process surfaces are reachable.
enum class ForegroundState(val raw: String) {
    FOREGROUND("foreground"),
    BACKGROUNDED_OR_LOCKED("backgroundedOrLocked");

    companion object {
        fun fromRaw(raw: String): ForegroundState = entries.first { it.raw == raw }
    }
}

/// §3 DeviceContext — host-supplied; the engine never reads lifecycle itself.
data class DeviceContext(
    var appState: ForegroundState = ForegroundState.FOREGROUND,
    var silenced: Boolean = false,
)

/// §3(a) one row of the cue→channel mapping table.
data class CueChannelSet(
    /// null = no haptic (BR-002: dropped / pr.summary / finish.morph / confirm).
    var haptic: HapticClass?,
    /// Only cue.rest.end carries audio; silenced devices drop it (BR-004).
    var audio: Boolean,
    /// INV-C3: every cue degrades to this visual element at minimum.
    var visual: String,
    /// Silenced = audio-only kill; haptic + visual still fire (#10 table).
    var firesSilenced: Boolean,
    /// INV-C6: true for exactly one cue — cue.rest.end (BR-005).
    var firesBackgroundedOrLocked: Boolean,
    /// INV-C5: true for exactly one cue — cue.confirm.destructive (BR-010).
    var blocking: Boolean,
)

/// BR-008 headline rule — one cue per set, precedence
/// max_1rm > max_volume > max_reps > max_duration (SC-prs BR-005 re-stated as
/// the cue-layer headline selection). Kind strings are SC-prs's canonical
/// raw values (INV-PR1 closed vocabulary); unknown kinds are ignored (BR-007).
object PRKindPrecedence {
    /// Highest precedence first.
    val order: List<String> = listOf("max_1rm", "max_volume", "max_reps", "max_duration")

    /// 0 = highest precedence; null for unknown kinds.
    fun rankOf(kind: String): Int? = order.indexOf(kind).takeIf { it >= 0 }

    /// The headline kind among the beaten kinds, or null when no known kind
    /// remains (empty / all-unknown ⇒ first-touch suppression, BR-007).
    fun headlineOf(beatenKinds: List<String>): String? {
        var best: String? = null
        var bestRank = Int.MAX_VALUE
        for (kind in beatenKinds) {
            val rank = rankOf(kind) ?: continue
            if (rank < bestRank) {
                bestRank = rank
                best = kind
            }
        }
        return best
    }
}
