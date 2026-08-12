// contractId: SC-cues @1.0.0
// The cue engine (§4/§5) — pure evaluation: one event in, zero or one
// dispatch out, with the BR-014 gate order: backgrounded (BR-005) → morph
// (BR-006) → first-touch (BR-007) → per-set budget (BR-008) → dedupe
// (BR-012) → dispatch. Pure JVM. The engine never reads a clock (INV-C2):
// every event carries its instant, and the accumulators it mutates live in
// CueState — in-memory only, never persisted (INV-C1).
// Mechanical Kotlin port of Sources/MooreCues/CueEngine.swift.
package com.moore.cues

/// One cue event presented to the engine. `at` is host-supplied (INV-C2),
/// epoch seconds. `nameRaw` is the port-wide cue ID string; INV-C7 unknown
/// ids never crash — they suppress with reason `unknownCue`.
data class CueEvent(
    val nameRaw: String,
    val at: Double,
    /// Per-set scope: the budget gate (BR-008) keys on this.
    val setId: String? = null,
    /// prAchieved only: the SC-prs PRWrite.beaten kinds. Empty/null ⇒
    /// first-touch suppression (BR-007); headline per BR-008.
    val beatenKinds: List<String>? = null,
) {
    val name: CueName? get() = CueName.fromRaw(nameRaw)

    constructor(name: CueName, at: Double, setId: String? = null, beatenKinds: List<String>? = null) :
        this(name.raw, at, setId, beatenKinds)
}

/// Delivery class of a fired dispatch (BR-005).
enum class CueDelivery(val raw: String) {
    /// In-process rendering via the CueSink seam.
    IN_PROCESS("inProcess"),
    /// Notification-class delivery — the host's local-notification surface
    /// (iOS UNUserNotificationCenter; Android WorkManager, #13) owns the
    /// rendering; only cue.rest.end ever carries it (INV-C6).
    LOCAL_NOTIFICATION("localNotification");
}

/// One fired cue, fully resolved against device context (§3).
data class CueDispatch(
    var cue: String,
    /// null = no haptic (BR-002).
    var haptic: HapticClass?,
    /// Silenced ⇒ false (BR-004).
    var audio: Boolean,
    /// INV-C3: always present — every cue degrades to visual-only.
    var visual: String,
    /// INV-C5: true only for cue.confirm.destructive (BR-010).
    var blocking: Boolean,
    var delivery: CueDelivery,
    /// prAchieved only (BR-008): the highest-precedence beaten kind.
    var headlineKind: String?,
)

/// Outcome of one evaluation, as recorded in the ring buffer (BR-013).
enum class CueOutcome(val raw: String) {
    FIRED("fired"), SUPPRESSED("suppressed"), DEDUPED("deduped");
}

/// Suppression/dedupe reasons — the first failing gate names it (BR-014).
object CueReason {
    const val BACKGROUNDED = "backgrounded"
    const val MORPHED_TO_FINISH = "morphedToFinish"
    const val FIRST_TOUCH = "firstTouch"
    const val PR_SUBSUMES = "prSubsumes"
    const val DEDUPE_500MS = "dedupe500ms"
    const val UNKNOWN_CUE = "unknownCue"
}

/// One ring-buffer entry (BR-013): fired AND non-fired outcomes are recorded.
data class CueLogEntry(
    var cue: String,
    var at: Double,
    var outcome: CueOutcome,
    var reason: String?,
)

/// §2a accumulators. Reference type so CueEngine.evaluate keeps its pure
/// signature; the engine is the sole mutator except the host's `context`
/// writes and resolveConfirmation() (§2b exit). Thread-safe via a single lock
/// (NSLock on iOS).
class CueState(context: DeviceContext = DeviceContext()) {

    companion object {
        /// INV-C1: FIFO ring capacity.
        const val ringCapacity = 64
        /// BR-012: same cue strictly inside this window collapses.
        const val dedupeWindowSec = 0.5
        /// BR-005 host scheduling: re-foreground within this span of expiry
        /// favors the in-process cue over the notification.
        const val backgroundedNotificationGraceSec = 10.0
    }

    private val lock = Any()
    private var storedContext: DeviceContext = context
    private val lastFiredAt = HashMap<String, Double>()
    private val prFiredSetIds = HashSet<String>()
    private var storedMorphLatch = false
    private var storedPendingConfirmation = false
    private val storedLog = ArrayList<CueLogEntry>()

    // MARK: Host surface

    /// Host lifecycle feeds this; the engine reads it per evaluation.
    var context: DeviceContext
        get() = synchronized(lock) { storedContext.copy() }
        set(value) = synchronized(lock) { storedContext = value }

    /// §2b latch: a finish morph has consumed the overlay and no new set has
    /// unlatched it (SC-rest INV-T6 mirrored at the cue layer).
    val overlayMorphedToFinish: Boolean
        get() = synchronized(lock) { storedMorphLatch }

    /// §2b confirm machine: a blocking confirm is on screen (BR-010).
    val pendingConfirmation: Boolean
        get() = synchronized(lock) { storedPendingConfirmation }

    /// The ring buffer, oldest → newest (BR-013). Summary/diagnostics read it.
    val log: List<CueLogEntry>
        get() = synchronized(lock) { storedLog.toList() }

    /// Harness bookkeeping (not contract surface): monotonic count of every
    /// appended entry, so wrap-around is observable despite FIFO eviction.
    val totalEntries: Int
        get() = synchronized(lock) { storedTotalEntries }
    private var storedTotalEntries = 0

    /// §2b exit: explicit acceptance (the destructive write may now execute)
    /// or explicit rejection (it must not). No other event resolves a confirm.
    fun resolveConfirmation() {
        synchronized(lock) { storedPendingConfirmation = false }
    }

    // MARK: Engine-only mutation (single critical section per evaluate)

    /// Run `body` holding the state lock — CueEngine evaluates atomically.
    fun <T> withLock(body: () -> T): T = synchronized(lock) { body() }

    internal fun recordFire(event: CueEvent, reason: String?) {
        storedLog.add(CueLogEntry(event.nameRaw, event.at, CueOutcome.FIRED, reason))
        evictIfNeeded()
        lastFiredAt[event.nameRaw] = event.at
    }

    internal fun recordSuppressed(event: CueEvent, reason: String) {
        storedLog.add(CueLogEntry(event.nameRaw, event.at, CueOutcome.SUPPRESSED, reason))
        evictIfNeeded()
    }

    internal fun recordDeduped(event: CueEvent) {
        storedLog.add(CueLogEntry(event.nameRaw, event.at, CueOutcome.DEDUPED, CueReason.DEDUPE_500MS))
        evictIfNeeded()
    }

    private fun evictIfNeeded() {
        storedTotalEntries += 1
        while (storedLog.size > ringCapacity) {
            storedLog.removeAt(0)
        }
    }

    internal fun lastFiredAt(nameRaw: String): Double? = lastFiredAt[nameRaw]
    internal fun currentContext(): DeviceContext = storedContext
    internal fun morphLatch(): Boolean = storedMorphLatch
    internal fun setMorphLatch(value: Boolean) { storedMorphLatch = value }
    internal fun prFiredContains(setId: String): Boolean = prFiredSetIds.contains(setId)
    internal fun markPrFired(setId: String) { prFiredSetIds.add(setId) }
    internal fun setPendingConfirmation(value: Boolean) { storedPendingConfirmation = value }
}

/// The pure engine. Deterministic in (event, state); commits the §2a side
/// effects; never reads a clock (INV-C2).
object CueEngine {

    /// One evaluation (BR-014 gate order). Returns zero or one dispatch.
    fun evaluate(event: CueEvent, state: CueState): List<CueDispatch> {
        return state.withLock {
            // INV-C7: unknown/forward-compat cue id ⇒ suppressed, never a crash.
            val cueName = event.name
            if (cueName == null) {
                state.recordSuppressed(event, CueReason.UNKNOWN_CUE)
                return@withLock emptyList<CueDispatch>()
            }
            val channels = cueName.channels
            val context = state.currentContext()

            // Gate 1 — BR-005 (INV-C6): only cue.rest.end reaches a
            // backgrounded/locked device; every other cue merely confirms
            // what the user is already doing.
            if (context.appState == ForegroundState.BACKGROUNDED_OR_LOCKED && cueName != CueName.REST_END) {
                state.recordSuppressed(event, CueReason.BACKGROUNDED)
                return@withLock emptyList<CueDispatch>()
            }

            // Gate 2 — BR-006: rest-end fires only while the overlay is in
            // the `rest` state. After a finish morph the morph IS the cue;
            // the latch clears only on a fired set log (INV-T6 unlatch).
            if (cueName == CueName.REST_END && state.morphLatch()) {
                state.recordSuppressed(event, CueReason.MORPHED_TO_FINISH)
                return@withLock emptyList<CueDispatch>()
            }

            // Gate 3 — BR-007: first-touch PR suppression. No beaten kinds
            // (no baseline existed to beat, SC-prs BR-002) ⇒ no cue. Unknown
            // kind strings are ignored; if no known kind remains, firstTouch.
            var headlineKind: String? = null
            if (cueName == CueName.PR_ACHIEVED) {
                headlineKind = PRKindPrecedence.headlineOf(event.beatenKinds ?: emptyList())
                if (headlineKind == null) {
                    state.recordSuppressed(event, CueReason.FIRST_TOUCH)
                    return@withLock emptyList<CueDispatch>()
                }
            }

            // Gate 4 — BR-008 (INV-C4): the celebration subsumes the tick.
            // A fired prAchieved recorded its setId; the completion tick for
            // that same set never fires a second haptic.
            val eventSetId = event.setId
            if (cueName == CueName.SET_COMPLETED && eventSetId != null && state.prFiredContains(eventSetId)) {
                state.recordSuppressed(event, CueReason.PR_SUBSUMES)
                return@withLock emptyList<CueDispatch>()
            }

            // Gate 5 — BR-012: same cue strictly inside 500ms of its last
            // FIRED dispatch collapses. The boundary (exactly 500ms) fires;
            // suppressed/deduped evaluations never advance the window.
            val last = state.lastFiredAt(event.nameRaw)
            if (last != null && event.at - last < CueState.dedupeWindowSec) {
                state.recordDeduped(event)
                return@withLock emptyList<CueDispatch>()
            }

            // Dispatch — BR-002/BR-004 channel resolution, BR-005 delivery.
            val audio = channels.audio && !context.silenced
            val delivery =
                if (cueName == CueName.REST_END && context.appState == ForegroundState.BACKGROUNDED_OR_LOCKED)
                    CueDelivery.LOCAL_NOTIFICATION
                else CueDelivery.IN_PROCESS
            val dispatch = CueDispatch(
                cue = event.nameRaw,
                haptic = channels.haptic,
                audio = audio,
                visual = channels.visual,
                blocking = channels.blocking,
                delivery = delivery,
                headlineKind = headlineKind,
            )

            // Commit side effects (§2a). Fired outcomes only.
            state.recordFire(event, null)
            when (cueName) {
                CueName.FINISH_MORPH -> state.setMorphLatch(true)
                // SC-rest INV-T6: a new set log unlatches the overlay to
                // `rest` — only the new run's own terminal flag decides
                // whether ITS expiry morphs.
                CueName.SET_COMPLETED, CueName.SET_FAILED -> state.setMorphLatch(false)
                CueName.PR_ACHIEVED -> {
                    if (eventSetId != null) state.markPrFired(eventSetId)
                }
                CueName.CONFIRM_DESTRUCTIVE -> state.setPendingConfirmation(true)
                CueName.REST_END, CueName.SET_DROPPED, CueName.PR_SUMMARY -> Unit
            }
            listOf(dispatch)
        }
    }
}
