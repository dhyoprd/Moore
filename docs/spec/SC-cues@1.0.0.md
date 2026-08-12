# Contract: Haptics + Cue System

```yaml
---
contractId: "SC-cues"
version: "1.0.0"
status: frozen
date: "2026-08-12"
source: "#29"
supersedes: null
supersededBy: null
---
```

One concern, one contract: the **sensory layer** — every user gesture produces appropriate, consistent sensory feedback; no random beeps, no surprise haptics. This contract owns #10's complete cue taxonomy as executable logic: the eight named cues, the four haptic classes, the cue→channel mapping, every suppression/gating rule (morph, backgrounded, silenced, first-touch, per-set budget), the 500 ms dedupe, the blocking-confirm machine, and the in-memory cue log.

This contract **extends, never duplicates**, the seam defined by `SC-rest@1.0.0` §5: it supplies the concrete `CueDispatching` implementation (`CueDispatcher`) that SC-rest BR-008 deliberately left as "#29's platform seam", and adopts SC-rest's `InMemoryCueDispatcher` as the integration spy unchanged. It consumes `SC-prs@1.0.0` (`PRFiredCue` is the sole origin of `cue.pr.achieved`; precedence and first-touch semantics are re-stated here only as cue-layer gates on events that path produces) and `SC-workout-logging@1.0.0` (set lifecycle events; discard-session confirm). It adds **no tables, no migrations, no persisted state** — the cue log is an in-memory ring buffer (INV-C1), in the same spirit as SC-rest's INV-T2. The module imports no UIKit/CoreHaptics: platform delivery sits behind the `CueSink` protocol seam (§5), so the Android port (#8) implements from this file exact-version.

**The budget, verbatim from #10:** *the money screen is used with sweaty hands, a silenced phone in a pocket, and attention already spent on the bar. Cues in this app are witnesses, not bosses: every tap confirms itself (haptic-first, because the gym phone vibrates), no cue ever blocks the ✓ path or demands attention to continue, and only one cue in the whole app may cross the room to fetch you — the rest-end alert. Everything else degrades gracefully: silenced kills audio, backgrounded kills toasts, and the visual element always remains, because a cue you can safely ignore is the only kind that belongs between sets.*

## 2. State Machine

### 2a. Engine accumulators (not user-reachable states)

`CueEngine.evaluate` is a pure function of `(event, state)` (INV-C2); `CueState` carries the accumulators the rules need. None of it is user-visible; all of it is in-memory.

| Accumulator | Meaning | Written by | Read by |
|---|---|---|---|
| `context: DeviceContext` | `{ appState: foreground \| backgroundedOrLocked, silenced: Bool }`, supplied by host lifecycle — the engine never reads it itself. | Host, on lifecycle change. | BR-004, BR-005. |
| `lastFiredAt: [CueName: Instant]` | Per-cue instant of the last **fired** dispatch. | A fired dispatch (BR-012). | BR-012 dedupe. |
| `overlayMorphedToFinish: Bool` | The §2b latch of SC-rest mirrored at the cue layer: a finish morph has consumed the overlay and no new set has unlatched it. | Fired `cue.finish.morph` sets true; fired `cue.set.completed` / `cue.set.failed` clear it (SC-rest INV-T6); `cue.set.dropped` does **not** (a drop touches neither rest nor overlay, SC-rest BR-005). | BR-006. |
| `prFiredSetIds: Set<String>` | setIds for which `cue.pr.achieved` fired. | Fired `cue.pr.achieved` with a setId (BR-008). | BR-008 budget. |
| `pendingConfirmation: Bool` | A blocking confirm is on screen (§2b). | Fired `cue.confirm.destructive` sets; `resolveConfirmation()` clears. | BR-010, INV-C5. |
| `log: [CueLogEntry]` ring, capacity 64 | Every evaluation's outcome, fired or not (BR-013). | Every `evaluate` call. | Summary/diagnostics seam. |

### 2b. Confirm machine (the only blocking surface in v1)

| State | Meaning | Entered by | Exits |
|---|---|---|---|
| `noConfirm` | No destructive action awaiting a decision. Starting state. | Initial; or resolution below. | → `confirmPending` on a fired `cue.confirm.destructive` (one of: discard session, delete routine, delete folder — SC-routines BR-004). |
| `confirmPending` | Modal confirm presented; the destructive write **must not execute** (BR-010). | ← fired `cue.confirm.destructive`. | → `noConfirm` via explicit acceptance (write may now execute) or explicit rejection (write must not execute), both through `resolveConfirmation()`. No other exit: backgrounding, timers, and other cues never resolve it. |

**Invariants**

- **INV-C1 (ring is memory):** the cue log is a fixed-capacity 64-entry FIFO ring, never persisted, never synced — analytics never persists (SC-foundation invariant 5).
- **INV-C2 (no wall clock):** the engine never reads time itself; every event carries its instant (`at`), supplied by the host — same discipline as SC-rest's `at:` actions.
- **INV-C3 (visual floor):** every fired dispatch carries a visual element. Every cue degrades to visual-only; a cue with no renderable remainder does not exist.
- **INV-C4 (one haptic per set):** at most one haptic fires per setId (BR-008); the celebration pattern subsumes the success tick.
- **INV-C5 (one blocking cue):** `cue.confirm.destructive` is the only cue whose dispatch carries `blocking = true`, and the only UI in v1 that may interrupt a flow.
- **INV-C6 (one summoner):** `cue.rest.end` is the only cue delivered while `backgroundedOrLocked` (BR-005) — it is the sole cue that summons the user; every other cue merely confirms what they are already doing.

## 3. Data Schema

No persisted entities. Derived/transient types only (exist for the duration of a process; nothing stored):

```
CueName        = cue.rest.end | cue.set.completed | cue.set.failed | cue.set.dropped
               | cue.pr.achieved | cue.pr.summary | cue.finish.morph | cue.confirm.destructive
HapticClass    = success | nudge | alert | celebration
Foreground     = foreground | backgroundedOrLocked
DeviceContext  = { appState: Foreground, silenced: Bool }
CueEvent       = { name: CueName, at: Instant, setId?, beatenKinds?: [String] }   -- beatenKinds: prAchieved only
CueDispatch    = { cue: CueName, haptic: HapticClass?, audio: Bool, visual: String,
                   blocking: Bool, delivery: inProcess|localNotification, headlineKind: String? }
CueLogEntry    = { cue: CueName, at: Instant, outcome: fired|suppressed|deduped, reason: String? }
CueChannelSet  = { haptic: HapticClass?, audio: Bool, visual: String,
                   firesSilenced: Bool, firesBackgroundedOrLocked: Bool, blocking: Bool }
```

### (a) Cue→channel mapping (#10 taxonomy, verbatim)

| Cue ID | Trigger (owner contract) | Haptic | Audio | Visual element | Blocking | Fires silenced | Fires bg/locked |
|---|---|---|---|---|---|---|---|
| `cue.rest.end` | Rest expiry, overlay still in `rest` state (SC-rest BR-008) | `alert` | one short tone | `rest.over` — overlay flips to rest-over state | No | yes (haptic + visual; audio contributes nothing) | yes — delivery class `localNotification` |
| `cue.set.completed` | Set → `completed` (✓ tap or sheet ✓; SC-workout-logging) | `success` | silent | `set.checkFill` — ✓ fills; planned-vs-actual delta | No | yes | no — suppressed, reason `backgrounded` |
| `cue.set.failed` | Set → `failed`, actuals saved | `nudge` | silent | `set.failDelta` — ✗ row delta | No | yes | no — suppressed |
| `cue.set.dropped` | Set → `dropped` | **none** | silent | `set.dropUndo` — row greys + persistent undo toolbar | No | yes | no — suppressed |
| `cue.pr.achieved` | `PRFiredCue` returned by SC-prs live path (BR-002 of SC-prs gates it) | `celebration` (max one per set) | silent | `pr.toast` — compact toast, ≥3s, queued one-at-a-time | No | yes | no — suppressed (foreground-only by construction) |
| `cue.pr.summary` | Summary renders with ≥1 PR row (SC-prs BR-010) | none | silent | `pr.cards` — stacked cards (+ banner ≥2) | No | yes | no — suppressed |
| `cue.finish.morph` | Final-set rest expires/skipped with all sets terminal (SC-rest §2b) | none | silent | `finish.morph` — overlay mutates into Finish CTA + mini-summary | No | yes | no — suppressed |
| `cue.confirm.destructive` | Discard session / delete routine / delete folder invoked | none | silent | `confirm.modal` — title + consequence + destructive action + cancel | **Yes** | yes | no — suppressed |

### (b) Haptic classes (#10, verbatim character)

| Class | Character (platform-agnostic) |
|---|---|
| `success` | Single light tick — "logged" |
| `nudge` | Single medium tap — "attention warranted, nothing wrong" |
| `alert` | Repeated urgent pattern — "return to work now" |
| `celebration` | Distinct multi-stage pattern — "achievement"; used by exactly one cue per set |

### (c) Invariants

INV-C1…INV-C6 (§2). Plus:

7. **INV-C7 (closed vocabulary):** writers only ever emit the eight `CueName` values / cue-id strings; an unknown id is suppressed with reason `unknownCue`, never a crash (forward compatibility — future cue ids degrade to nothing until a port adds them).

## 4. Business Rules

- **BR-001 (closed taxonomy, forward-compatible):** v1 has exactly eight cues, addressed by the IDs of §3(a). Unknown/forward-compat cue ids evaluate to zero dispatches with outcome `suppressed`, reason `unknownCue`. (Source: #10)
- **BR-002 (channel mapping):** each cue's channels are exactly the §3(a) table. `cue.set.dropped`, `cue.pr.summary`, `cue.finish.morph`, `cue.confirm.destructive` carry **no haptic**; only `cue.rest.end` carries audio; every cue carries a visual element (INV-C3). (Source: #10)
- **BR-003 (four classes):** haptic patterns are drawn only from `success | nudge | alert | celebration` (§3b); `celebration` is used by exactly one cue (`cue.pr.achieved`), max one per set. (Source: #10)
- **BR-004 (silenced degradation):** when `context.silenced`, the audio channel contributes nothing — `audio = false` on the dispatch — while haptic + visual fire unchanged. No cue is ever sound-dependent (#9 point 2). (Source: #10, #9)
- **BR-005 (one summoner):** when `context.appState = backgroundedOrLocked`, only `cue.rest.end` evaluates to a dispatch, with `delivery = localNotification`; every other cue is suppressed with reason `backgrounded` (INV-C6). Host scheduling contract: the local notification is scheduled for the expiry instant when a rest run starts, and is cancelled if the app is foreground at expiry; a re-foreground within `backgroundedNotificationGraceSec = 10` of expiry suppresses the notification in favor of the in-process cue (first-deliverable-opportunity, #10's firing-moment ruling). (Source: #10, #9 point 3, #29)
- **BR-006 (morph suppression + unlatch):** `cue.rest.end` evaluates to zero dispatches while `overlayMorphedToFinish` is set — reason `morphedToFinish` — because the morph *is* the cue (visual only, zero haptic, zero audio; #10 finish-morph rule, SC-rest §2b). A fired `cue.finish.morph` sets the latch; a fired `cue.set.completed`/`cue.set.failed` clears it (SC-rest INV-T6 — a new set log unlatches the overlay to `rest`, so only the new run's own terminal flag decides its ending); `cue.set.dropped` never clears it. (Source: #10, SC-rest §2b)
- **BR-007 (first-touch PR suppression):** `cue.pr.achieved` with empty `beatenKinds` (no baseline row existed to beat — SC-prs BR-002) evaluates to zero dispatches, reason `firstTouch`. Unknown kind strings are ignored when selecting the headline; if no known kind remains, the event suppresses as `firstTouch`. Re-derivation (SC-prs BR-009) never produces cue events at all — no retroactive promotion. (Source: #10 tier 1, SC-prs BR-002)
- **BR-008 (one cue per set, precedence):** at most one haptic fires per setId (INV-C4). When one set beats multiple PR kinds, the dispatch's `headlineKind` is the highest-precedence beaten kind — `max_1rm > max_volume > max_reps > max_duration` (SC-prs BR-005, re-stated as the cue-layer headline rule); the toast names the headline kind only, other kinds surface silently on Summary. A fired `cue.pr.achieved` records its setId; any subsequent `cue.set.completed` carrying that setId is suppressed with reason `prSubsumes` — the celebration subsumes the tick. Callers evaluate the PR cue **before** the completion tick (SC-prs BR-006 returns `fired` inside the completion transaction, so this order is the natural one). (Source: #10, SC-prs BR-005)
- **BR-009 (drop has no haptic):** `cue.set.dropped` dispatches visual-only (`set.dropUndo`) — haptic `null`, audio `false`. Undoing a drop fires **no** cue: undo within-drop never double-fires. The undo toolbar persists until the next set logs, no timer (#10 drop-undo window). (Source: #10, #29)
- **BR-010 (the only blocking cue):** `cue.confirm.destructive` is the sole blocking cue (INV-C5): its dispatch carries `blocking = true` and sets `pendingConfirmation`. While pending, the destructive write must not execute; it executes only after explicit acceptance via `resolveConfirmation()`, and explicit rejection must abort it. Exactly three actions route through it — discard session, delete routine, delete folder (SC-routines BR-004). No confirm on drop (undo covers it), none on set edits. The confirm itself carries no haptic: a decision demanded by buzz is a boss, not a witness. (Source: #10, SC-routines BR-004)
- **BR-011 (never block the ✓ path):** cues are post-commit witnesses. No cue may interpose between the ✓ tap and the set log, and no dispatch produced by the one-tap accept path carries `blocking = true` (SC-rest INV-T5: rest never gates logging; this contract: nothing else does either). (Source: #10 philosophy)
- **BR-012 (dedupe, 500 ms):** the same cue name evaluated strictly less than `0.500 s` after its last **fired** dispatch collapses to zero dispatches, reason `dedupe500ms`; an interval ≥ 0.500 s fires. The window is keyed by cue name (not by setId — set-level collision is BR-008's job), measured event-instant to last-fired instant; suppressed/deduped evaluations do not advance the window. Defense-in-depth under SC-rest INV-T3 (fire-once) and a guard against double-tap misfires. (Source: #29)
- **BR-013 (cue log ring buffer):** every `evaluate` appends one `CueLogEntry { cue, at, outcome, reason }` — fired, suppressed, *and* deduped outcomes are all recorded. Capacity 64, FIFO eviction, in-memory only (INV-C1); the Summary screen and diagnostics read it, nothing persists it. (Source: #29)
- **BR-014 (fixed evaluation order):** gates run in exactly this order; the first failing gate names the reason: (1) backgrounded gate (BR-005) → (2) morph gate (BR-006) → (3) first-touch gate (BR-007) → (4) per-set budget gate (BR-008) → (5) dedupe (BR-012) → dispatch. Side effects (latches, window, budget set, pendingConfirmation, log) commit only as specified per rule. (Source: this contract)

## 5. API Contract

Local-only; streams nothing. The cue layer has no entity, therefore no sync surface (#4). `MooreCues` module; depends on Foundation only plus the `SC-rest` seam types (it **extends** SC-rest's `CueDispatching` — no second protocol, no second spy).

```swift
/// §3 vocabulary. Raw values are the port-wide cue IDs — code cites
/// "cue.rest.end", never a local name (#10 downstream ruling).
public enum CueName: String, CaseIterable, Codable, Sendable { /* 8 cases */ }
public enum HapticClass: String, CaseIterable, Codable, Sendable { case success, nudge, alert, celebration }
public struct CueChannelSet: Equatable, Sendable { /* §3(a) row */ }
extension CueName { public var channels: CueChannelSet { get } }        // the §3(a) table, in code

public enum ForegroundState: String, Codable, Sendable { case foreground, backgroundedOrLocked }
public struct DeviceContext: Equatable, Sendable { public var appState: ForegroundState; public var silenced: Bool }

public struct CueEvent: Equatable, Sendable {
    public var name: CueName
    public var at: Date                    // INV-C2: host-supplied instant
    public var setId: String?              // per-set scope (BR-008 budget)
    public var beatenKinds: [String]?      // prAchieved only (BR-007/BR-008)
}

public enum CueDelivery: String, Equatable, Sendable { case inProcess, localNotification }
public struct CueDispatch: Equatable, Sendable {
    public var cue: CueName
    public var haptic: HapticClass?        // nil = no haptic (BR-002)
    public var audio: Bool                 // silenced ⇒ false (BR-004)
    public var visual: String              // always present (INV-C3)
    public var blocking: Bool              // true only for confirm.destructive (INV-C5)
    public var delivery: CueDelivery       // BR-005
    public var headlineKind: String?       // prAchieved only (BR-008)
}

public enum CueOutcome: String, Equatable, Sendable { case fired, suppressed, deduped }
public struct CueLogEntry: Equatable, Sendable { public var cue: CueName; public var at: Date; public var outcome: CueOutcome; public var reason: String? }

/// §2a accumulators. Reference type so the pure signature below holds;
/// the engine is the sole mutator (plus host `context` + `resolveConfirmation`).
public final class CueState: @unchecked Sendable {
    public static let ringCapacity = 64                       // INV-C1
    public static let dedupeWindowSec: TimeInterval = 0.5     // BR-012
    public static let backgroundedNotificationGraceSec: TimeInterval = 10  // BR-005 host scheduling
    public var context: DeviceContext
    public private(set) var overlayMorphedToFinish: Bool
    public private(set) var pendingConfirmation: Bool
    public private(set) var log: [CueLogEntry]
    public func resolveConfirmation()                          // §2b exit
}

public enum CueEngine {
    /// One evaluation (BR-014 order). Returns zero or one dispatch.
    /// Deterministic in (event, state); commits §2a side effects; never reads a clock (INV-C2).
    public static func evaluate(_ event: CueEvent, state: CueState) -> [CueDispatch]
}

/// Platform delivery seam — the iOS host supplies a CoreHaptics /
/// UINotificationFeedbackGenerator-backed implementation; this module imports
/// neither. The Android port supplies its own (VibrationEffect, WorkManager
/// notification for delivery == localNotification — #13).
public protocol CueSink: Sendable {
    func playHaptic(_ hapticClass: HapticClass)
    func playTone()
    func presentVisual(_ element: String, forCue cue: CueName)
}

/// The concrete SC-rest seam: conforms to SC-rest's CueDispatching (EXTEND,
/// don't duplicate). RestCycle.dispatch(_:into:) accepts it directly.
public final class CueDispatcher: CueDispatching, @unchecked Sendable {
    public init(sink: CueSink, state: CueState = CueState(), clock: @escaping @Sendable () -> Date = { Date() })
    public func dispatch(_ cue: MooreRest.CueEvent)   // bridges restEnd/finishMorph → CueEvent
    public func dispatch(_ event: CueEvent)           // full-taxonomy entry (set/PR/confirm callers)
}
```

**Seams under test:**
- **Seam-1 (logic):** `CueEngine.evaluate` trajectories — verified in a JS mirror (deterministic, platform-free) against `Tests/MooreCuesTests/Fixtures/*.json`. The mirror is verbatim; if it drifts from the Swift, the frozen contract is the arbiter.
- **Seam-3 (integration):** SC-rest's `InMemoryCueDispatcher` remains the rest-channel spy (adopted unchanged); `RecordingCueSink` (spy `CueSink` in `CueDispatcher.swift`) records rendered haptic/tone/visual calls so fire order, silenced-mode behavior, and backgrounded delivery class are assertable without platform haptics.

## 6. UI Copy

New strings owned by this contract (the backgrounded/locked delivery surface of BR-005 — SC-rest owns the in-process overlay copy, this contract owns the notification-class rendering of the same cue):

| Key | String |
|---|---|
| `rest.notification.title` | "Rest over" |
| `rest.notification.body` | "{exerciseName} — set {n} of {total}" |

All other cue surfaces bind copy **owned by the surface contracts** — values live there, this table is the binding so no key is ever re-authored:

| Cue | Copy keys | Owner |
|---|---|---|
| `cue.rest.end` (in-process) | `rest.over.title`, `rest.over.body` | SC-rest §6 |
| `cue.pr.achieved` | `toast.pr.new` | SC-prs §6 |
| `cue.pr.summary` | `summary.pr.card`, `summary.pr.banner` | SC-prs §6 |
| `cue.finish.morph` | `rest.finish.cta`, `rest.finish.summary` | SC-rest §6 |
| `cue.set.dropped` (undo toolbar) | `workout.undo.title`, `workout.undo.cta` | SC-workout-logging §6 |
| `cue.confirm.destructive` | `confirm.discardSession.*` | SC-workout-logging §6 / SC-routines §6 |
| `cue.confirm.destructive` | `confirm.deleteRoutine.*`, `confirm.deleteFolder.*` | SC-routines §6 |

Voice per #17: declarative, factual, no exclamation marks.

## 7. Acceptance Criteria

Test fixtures under `Tests/MooreCuesTests/Fixtures/*.json` encode these vectors; `VerifyCues.mjs` runs them against the JS mirror of `CueEngine` (Seam-1) plus a source-parity check that the Swift `Cue.swift` channel table carries the same eight cue IDs and visual element IDs. Default context: `{ appState: foreground, silenced: false }` unless a vector sets otherwise.

| # | Setup | Action sequence | Expected | Cites |
|---|---|---|---|---|
| V1 | Default context. | Evaluate each of the 8 cues once (t = 0…7). | Each fires exactly once; dispatch descriptors byte-match §3(a): haptic class / audio / visual / blocking / delivery per row; `set.dropped`, `pr.summary`, `finish.morph`, `confirm.destructive` have `haptic = null`; only `rest.end` has `audio = true`; only `confirm.destructive` has `blocking = true`. Also: an unknown id `cue.bogus.future` ⇒ suppressed, reason `unknownCue`, zero dispatches. | BR-001, BR-002, BR-003, INV-C3, INV-C5 |
| V2 | Default. | `set.completed` at t=0, 0.3, 0.79, 1.0. | t=0 fired; t=0.3 deduped (0.3 < 0.5); t=0.79 fired (0.79 ≥ 0.5 from last-fired 0); t=1.0 deduped (0.21 < 0.5 from 0.79). Exactly 2 dispatches. | BR-012 |
| V3 | Default. | `rest.end` at t=0, 0.499, 0.999; then `set.completed` t=2.0 and `set.failed` t=2.1. | t=0 fired; 0.499 deduped (strictly < 0.5); 0.999 fired (boundary ≥ 0.5 fires). The two set cues, 100 ms apart but **different names**, both fire — window keys by cue name. | BR-012 |
| V4 | Default. | `finish.morph` t=0 → `rest.end` t=1, t=2 → `set.completed`(s1) t=3 → `rest.end` t=4. Second vector: `finish.morph` t=0 → `set.dropped` t=1 → `rest.end` t=2. | First: morph fired (latch set); both rest-ends suppressed `morphedToFinish`; set.completed fired and unlatched; rest.end at t=4 **fires**. Second: drop does not unlatch — rest.end still suppressed. | BR-006, SC-rest §2b/INV-T6 |
| V5 | Context `backgroundedOrLocked`. | `rest.end` t=0; `set.completed` t=1; `pr.achieved`(s1, [max_1rm]) t=2; then context → foreground; `set.completed`(s2) t=3. | t=0 fires with `delivery = localNotification` (haptic `alert` retained — the notification class delivers it); t=1, t=2 suppressed `backgrounded`; t=3 fires `inProcess`. | BR-005, INV-C6, #9 point 3 |
| V6 | Context `silenced`. | `rest.end` t=0; `set.completed` t=1. Counter-vector unsilenced: `rest.end`. | Silenced: `audio = false`, haptic `alert` + visual unchanged; set.completed haptic unchanged. Unsilenced: `audio = true`. | BR-004, #9 point 2 |
| V7 | Default. | `set.completed`(s1) t=0; `pr.achieved`(s1, beatenKinds `[]`) t=1. Variant: beatenKinds `["unknown_kind"]`. | Set tick fires; PR cue suppressed `firstTouch` (empty — no baseline to beat, SC-prs BR-002); unknown-kind variant also `firstTouch`. Fired cues: `cue.set.completed` only. | BR-007, SC-prs BR-002/BR-009 |
| V8 | Default. | `pr.achieved`(s1, [max_volume, max_reps, max_1rm]) t=0 → `set.completed`(s1) t=1. Variant B: (s2, [max_reps, max_duration]) → set.completed(s2). Variant C: (s3, [max_duration]). | Exactly one dispatch per set: headline `max_1rm` (A), `max_reps` (B), `max_duration` (C); haptic `celebration`; the completion tick for the same setId suppressed `prSubsumes`. One haptic per set. | BR-008, INV-C4, SC-prs BR-005 |
| V9 | Default. | `set.dropped`(d1) t=0; then `set.completed`(s-next) t=1. | Drop fires with `haptic = null`, visual `set.dropUndo`, non-blocking — the undo toolbar is the cue; undo itself fires nothing. Next set's tick unaffected (budget keys per setId). | BR-009, #10 table |
| V10 | Default. | `confirm.destructive` t=0; assert `pendingConfirmation`; `resolveConfirmation`; `confirm.destructive` t=2. | t=0 fires `blocking = true` (the only blocking cue), pending set; resolve clears it; t=2 fires again (2.0 ≥ 0.5). No destructive write may execute between request and explicit acceptance. | BR-010, INV-C5, SC-routines BR-004 |
| V11 | Default. | One-tap accept path: `set.completed`(s1) t=0 → `rest.end` t=90 → `set.completed`(s2) t=100. | Every dispatch `blocking = false`; nothing interposes between tap and log — cues are post-commit witnesses. | BR-011, INV-C5 |
| V12 | Default. | (A) Mixed: completed@0 fired, completed@0.2 deduped, rest.end@1 fired, finish.morph@2 fired, rest.end@3 suppressed. (B) `set.completed` ×70 at 0.5 s spacing. | (A) Ring holds all five entries in order with exact outcomes+reasons — fired *and* non-fired. (B) 70 fired entries ⇒ ring length exactly 64, oldest evicted (head at t=3.0, tail at t=34.5). | BR-013, INV-C1 |

Edge cases held: dedupe window advances only on fired dispatches (suppressed events never shield a later one); morph latch clears on fired `set.failed` exactly as on `set.completed`; `pr.achieved` without a setId still fires (budget keys only what it can key); an event with `beatenKinds` containing known + unknown kinds headlines on the known one.

## 8. Rejected Alternatives

(Inherited from #10 where marked; this contract adds its own below.)

- **Sound-dependent rest-end cue** → rejected (#10, re-affirming #9): silenced/locked is the gym norm; haptic-first, multi-channel.
- **Haptic/audio on the Finish morph** → rejected (#10): "return to work" with no work remaining is a contra-signal; the morph is its own cue.
- **Mid-workout escalation (multi-PR banner, sound on PR)** → rejected (#10): attention-demanding inside the flow state; escalation lives on Summary only.
- **Toasting first-touch "PRs"** → rejected (#10): session one would toast ~20 times and devalue the cue permanently.
- **Multiple toasts or one haptic per PR type from a single set** → rejected (#10): per-set budget is one haptic and one visible toast; headline type cues, the rest surface on Summary.
- **Notification-class escalation for PRs** → rejected (#10): nothing summons the user to an achievement; persisted rows + Summary re-derivation make loss impossible.
- **Cue engine owning the rest timer / scheduling expiry** → rejected: SC-rest owns expiry computation (recompute-from-timestamps, BR-007 there); this engine evaluates events only, at instants supplied to it (INV-C2).
- **Persisted cue history (append-only cue log table)** → rejected: analytics never persists (SC-foundation invariant 5); the ring buffer (BR-013) is diagnostics, not a timeline — the timeline is derivable from CompletedSet/PersonalRecord.
- **UIKit/CoreHaptics imports in the cue module** → rejected: the `CueSink` seam keeps the engine platform-free so the Android port (#8) and the JS verifier test identical logic; platform intensity mapping is host trivia (#7's "not yet specified" owns it).
- **Dedupe keyed by (cue, setId)** → rejected: set-level collision is already the budget rule's job (BR-008); a name-keyed window is simpler and catches the real-world case (double-tap misfire).
- **Haptic on the confirm dialog** → rejected: a buzz preceding a decision is a demand for attention; the witness budget forbids it (BR-010, philosophy).

## 9. Downstream Effects

- **Extends SC-rest@1.0.0 §5:** `CueDispatcher` is the concrete `CueDispatching` that SC-rest BR-008 named as "#29's platform seam" — `RestCycle.dispatch(_:into:)` accepts it directly; SC-rest's `InMemoryCueDispatcher` remains the seam-3 spy, adopted unchanged.
- **Consumes SC-prs@1.0.0:** `PRFiredCue` (live path only) is translated to `cue.pr.achieved` with `beatenKinds = PRWrite.beaten`; headline per BR-008. Re-derivation never cues (SC-prs BR-009 ⇒ no event).
- **Consumes SC-workout-logging@1.0.0:** set lifecycle → `cue.set.completed` / `set.failed` / `set.dropped` (post-commit, BR-011); discard-session invokes `cue.confirm.destructive`.
- **Feeds #7 (screen blueprint):** drop-undo toolbar (persistent, no timer), confirm modal shape (§3a visual `confirm.modal`), PR toast queue (one visible, FIFO), rest-over visual state — all bind §6 keys.
- **Feeds #13 (Android port ticket):** `delivery = localNotification` is the seam the WorkManager-equivalent implements; the eight cue IDs + four classes are the port vocabulary, exact-version.
- **Feeds #8 (Android port plan):** frozen at v1.0.0; the JS mirror + fixtures are the port-parity reference (reproduce V1–V12 and the contract reading works).
- **Feeds #28 (settings):** any future haptic-intensity or cue-toggle setting degrades *within* this contract's channel table (a silenced setting is already `context.silenced`), never by adding cues.
