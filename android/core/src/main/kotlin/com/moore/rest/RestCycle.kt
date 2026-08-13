// contractId: SC-rest @1.0.0
// The rest-cycle state machine (§2a) + parallel overlay morph axis (§2b).
// Pure value type: no persistence, no platform imports, no wall-clock reads —
// every action carries its instant (`at`) from #22's caller. Timer state is
// in-memory only (INV-T2); nothing here is ever persisted.
// Mechanical Kotlin port of Sources/MooreRest/RestCycle.swift + RestResolver.swift.
// Instants are epoch seconds (Double); closed-form arithmetic mirrors Swift Date math.
package com.moore.rest

import kotlin.math.max
import kotlin.math.min

/// One cue emitted into the abstract channel (#10 taxonomy). Concrete delivery
/// (haptic alert + tone + visual; notification-class when backgrounded) is #29's
/// seam — this module only emits the event. Named RestCueEvent in the Kotlin
/// port to disambiguate from com.moore.cues.CueEvent (Swift kept them in
/// separate modules of the same name).
enum class RestCueEvent(val raw: String) {
    /// `cue.rest.end` — haptic alert + one short tone + visual rest-over flip.
    REST_END("cue.rest.end"),
    /// `cue.finish.morph` — visual only; the morph is the entire cue (#10).
    FINISH_MORPH("cue.finish.morph");
}

/// BR-001 resolution input + where the duration came from (observability only;
/// never persisted — INV-T2).
enum class RestSource(val raw: String) {
    PER_SET("perSet"),
    PER_EXERCISE("perExercise"),
    PER_ROUTINE("perRoutine"),
    GLOBAL_COMPOUND("globalCompound"),
    GLOBAL_ISOLATION("globalIsolation");
}

/// The result of a BR-001 walk: the clamped duration plus where it came from.
data class RestResolution(
    var durationSec: Int,
    var source: RestSource,
)

/// Level-4 global defaults (#9 v1: compound 180s / isolation 90s). Value type;
/// persisted against the migration-0008 app_setting singleton rows.
data class RestSettings(
    var defaultRestCompoundSec: Int,
    var defaultRestIsolationSec: Int,
) {
    companion object {
        /// The #9 v1 defaults, matching the 0008 seed (INV-S2).
        val DEFAULT = RestSettings(defaultRestCompoundSec = 180, defaultRestIsolationSec = 90)
    }
}

object RestResolver {
    /// BR-001: walk per-set → per-exercise → per-routine → global, first
    /// non-null wins. The global default is bucketed by exercise category —
    /// compound ⇒ defaultRestCompoundSec, everything else (isolation AND all
    /// duration-metric exercises, #9) ⇒ defaultRestIsolationSec. The winner
    /// is clamped to [0, 600]s (INV-S3). Total because settings are guaranteed
    /// seeded (INV-S2).
    fun resolve(
        perSetSec: Int?,
        perExerciseSec: Int?,
        perRoutineSec: Int?,
        categoryIsCompound: Boolean,
        settings: RestSettings,
    ): RestResolution {
        if (perSetSec != null) return clamped(perSetSec, RestSource.PER_SET)
        if (perExerciseSec != null) return clamped(perExerciseSec, RestSource.PER_EXERCISE)
        if (perRoutineSec != null) return clamped(perRoutineSec, RestSource.PER_ROUTINE)
        return if (categoryIsCompound)
            clamped(settings.defaultRestCompoundSec, RestSource.GLOBAL_COMPOUND)
        else
            clamped(settings.defaultRestIsolationSec, RestSource.GLOBAL_ISOLATION)
    }

    private fun clamped(durationSec: Int, source: RestSource): RestResolution {
        val clamped = min(max(durationSec, RestCycle.minDurationSec), RestCycle.maxDurationSec)
        return RestResolution(clamped, source)
    }
}

/// Actions dispatched into the cycle (§5). setCompleted/setFailed carry the
/// BR-001-resolved duration for the newly logged set (INV-T1).
sealed class RestAction {
    data class SetCompleted(val resolution: RestResolution, val allSetsTerminal: Boolean, val at: Double) : RestAction()
    data class SetFailed(val resolution: RestResolution, val allSetsTerminal: Boolean, val at: Double) : RestAction()
    object SetDropped : RestAction()
    data class Skip(val at: Double) : RestAction()
    data class AdjustSec(val delta: Int, val at: Double) : RestAction()
    data class ExpireNaturally(val at: Double) : RestAction()
    data class Backgrounded(val at: Double) : RestAction()
}

class RestCycle {

    /// §2a rest-cycle states.
    sealed class State {
        object NoRest : State()
        data class RestRunning(val durationSec: Int, val startedAt: Double, val adjustmentSec: Int) : State()
        data class RestExpired(val durationSec: Int, val startedAt: Double, val adjustmentSec: Int) : State()

        val kind: String
            get() = when (this) {
                NoRest -> "noRest"
                is RestRunning -> "restRunning"
                is RestExpired -> "restExpired"
            }
    }

    /// §2b parallel overlay surface axis.
    enum class Overlay(val raw: String) { REST("rest"), FINISH_PANEL("finishPanel") }

    var state: State = State.NoRest
        private set
    var overlay: Overlay = Overlay.REST
        private set
    /// §2b latch: set at each set log (the caller knows session-wide terminality).
    /// Consumed when the current run expires or is skipped — the morph decision.
    var allSetsTerminal: Boolean = false
        private set

    companion object {
        /// Hard clamps for adjustments and resolution (BR-002, INV-S3).
        const val minDurationSec = 0
        const val maxDurationSec = 600

        /// Absolute expiry instant of a run.
        fun expiresAt(durationSec: Int, startedAt: Double, adjustmentSec: Int): Double =
            startedAt + (durationSec + adjustmentSec)

        /// Remaining seconds at `now`; ≤ 0 means expired (BR-007 presents as expired).
        /// Int truncation toward zero mirrors Swift `Int(TimeInterval)`.
        fun remainingSec(durationSec: Int, startedAt: Double, adjustmentSec: Int, now: Double): Int =
            (expiresAt(durationSec, startedAt, adjustmentSec) - now).toInt()

        private fun clamp(durationSec: Int): Int =
            min(max(durationSec, minDurationSec), maxDurationSec)

        /// Cap the effective total span (duration + adjustment) at maxDurationSec by
        /// shrinking the adjustment, never touching the resolved duration itself.
        private fun clampSpan(durationSec: Int, adjustmentSec: Int): Int {
            val total = durationSec + adjustmentSec
            if (total <= maxDurationSec) return adjustmentSec
            return maxDurationSec - durationSec
        }
    }

    /// The surface #22's money screen binds to (§5).
    val current: State get() = state

    // MARK: - Transitions (§2a/2b matrices)

    /// Apply one action; return the cue to dispatch, or null when none fires
    /// (INV-T3 fire-once: a morphed or skipped run emits nothing at expiry).
    /// The FSM never touches a dispatcher itself — it emits the event and the
    /// caller routes it.
    fun dispatch(action: RestAction): RestCueEvent? {
        return when (action) {
            is RestAction.SetCompleted, is RestAction.SetFailed -> {
                val resolution = when (action) {
                    is RestAction.SetCompleted -> action.resolution
                    is RestAction.SetFailed -> action.resolution
                    else -> error("unreachable")
                }
                val terminal = when (action) {
                    is RestAction.SetCompleted -> action.allSetsTerminal
                    is RestAction.SetFailed -> action.allSetsTerminal
                    else -> error("unreachable")
                }
                val at = when (action) {
                    is RestAction.SetCompleted -> action.at
                    is RestAction.SetFailed -> action.at
                    else -> error("unreachable")
                }
                // BR-001/INV-T1: fresh run with the new set's resolved duration.
                // BR-004: restart discards the old run un-cued and resets adjustment
                // to 0. BR-006/INV-T4: the final set starts rest exactly like every
                // other set; terminal only latches the §2b morph decision. A fresh
                // run always unlatches the overlay to rest (INV-T6).
                val clamped = clamp(resolution.durationSec)
                state = State.RestRunning(durationSec = clamped, startedAt = at, adjustmentSec = 0)
                allSetsTerminal = terminal
                overlay = Overlay.REST
                null
            }

            // BR-005: a drop never starts rest, and never modifies a run.
            is RestAction.SetDropped -> null

            is RestAction.Skip -> {
                // BR-003: instant cancel/dismiss, no write, no cue from the rest
                // channel. If nothing actionable remains (§2b latch), skipping the
                // final rest morphs to the finish panel — the morph is the cue.
                when (state) {
                    is State.NoRest -> null
                    is State.RestRunning, is State.RestExpired -> {
                        if (allSetsTerminal) {
                            state = State.NoRest
                            overlay = Overlay.FINISH_PANEL
                            RestCueEvent.FINISH_MORPH
                        } else {
                            state = State.NoRest
                            null
                        }
                    }
                }
            }

            is RestAction.AdjustSec -> {
                // BR-002: accumulate onto the running timer; clamped; ≤0 remaining
                // is skip-equivalent. Never persisted (INV-T2).
                val s = state
                if (s !is State.RestRunning) {
                    null // adjusting a non-running timer is a no-op
                } else {
                    val newAdjustment = s.adjustmentSec + action.delta
                    val remaining = remainingSec(s.durationSec, s.startedAt, newAdjustment, action.at)
                    if (remaining <= 0) {
                        // −15 with <15s remaining ⇒ skip (BR-002/BR-003): no cue.
                        state = State.NoRest
                        null
                    } else {
                        // Clamp total span to [0, 600]s via the accumulated adjustment (INV-S3).
                        val capped = clampSpan(s.durationSec, newAdjustment)
                        state = State.RestRunning(s.durationSec, s.startedAt, capped)
                        null
                    }
                }
            }

            is RestAction.ExpireNaturally -> expire(at = action.at)
            // BR-007: recompute from timestamps; identical path to relaunch.
            is RestAction.Backgrounded -> expire(at = action.at)
        }
    }

    // MARK: - Internals

    /// Shared expiry/recompute path for expireNaturally and backgrounded
    /// (BR-007). Emits cue.rest.end at most once per run (INV-T3), gated to
    /// the overlay's rest state. A final-set run (§2b latch) morphs instead —
    /// the morph is the entire cue, zero haptic, zero audio (#10).
    private fun expire(at: Double): RestCueEvent? {
        return when (val s = state) {
            is State.NoRest -> null
            // Already expired; cue was emitted on first crossing (or the morph
            // already consumed the run). Re-arrival is a no-op (INV-T3).
            is State.RestExpired -> null
            is State.RestRunning -> {
                val remaining = remainingSec(s.durationSec, s.startedAt, s.adjustmentSec, at)
                if (remaining > 0) {
                    null // still running; recompute only, no state change
                } else if (allSetsTerminal) {
                    // §2b: the expiring final-set rest morphs to the finish panel.
                    state = State.NoRest
                    overlay = Overlay.FINISH_PANEL
                    RestCueEvent.FINISH_MORPH
                } else {
                    // Ordinary expiry: fire cue.rest.end exactly once.
                    state = State.RestExpired(s.durationSec, s.startedAt, s.adjustmentSec)
                    RestCueEvent.REST_END
                }
            }
        }
    }
}

/// Cue-channel bridge (§5; abstract channel, concrete delivery in #29).
interface CueDispatching {
    fun dispatch(cue: RestCueEvent)
}

/// Apply an action and route any emitted cue into `channel`. BR-008 seam.
/// (Swift: `dispatch(_:into:)`; `into` is a Kotlin keyword, so `dispatchInto`.)
fun RestCycle.dispatchInto(action: RestAction, channel: CueDispatching): RestCueEvent? {
    val cue = dispatch(action)
    if (cue != null) channel.dispatch(cue)
    return cue
}
