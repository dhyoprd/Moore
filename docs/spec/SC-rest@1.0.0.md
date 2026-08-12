# Contract: Ambient Rest Timer + Cue Dispatch

```yaml
---
contractId: "SC-rest"
version: "1.0.0"
status: frozen
date: "2026-08-11"
source: "#23"
supersedes: null
supersededBy: null
---
```

One concern, one contract: the **ambient rest cycle** — rest that starts itself the moment a set is logged, resolves its duration through #9's four-level hierarchy, adapts to the gym's pace via one-off ±15s steppers, fires exactly one multi-channel cue at expiry, and never orphans on app kill. A unit tested against this contract never needs to know whether the countdown UI ticks, whether a local notification was scheduled, or whether the device was locked — those are platform delivery details hidden behind the cue channel below.

This contract consumes `SC-foundation@1.0.0` (schema, migrations 0001–0003), `SC-exercises@1.0.0` (`Exercise.defaultRestSec`, BR-009), and `SC-routines@1.0.0` (the `Routine` row that gains `restSec`). It adopts verbatim the rest source-of-truth (#9 resolution comment) and the cue taxonomy (#10 resolution comment). It adds **no new tables**; migration `0007_rest_fields.sql` (§3d) is additive-only: one column on `routine`, one singleton key-value table for settings. The transient timer state (`restStartedAt`, duration) is **in-memory only** (#9: "the timer never writes anything, anywhere, ever") — nothing about a running rest is persisted, which is precisely why recompute-from-timestamps (BR-007) works.

## 2. State Machine

### 2a. Rest cycle

A session's rest layer is in exactly one of these states at a time.

| State | Meaning | Entered by | Exits |
|---|---|---|---|
| `noRest` | No timer running; no overlay shown. The session's starting state. | Initial; or terminal transitions below. | → `restRunning(durationSec)` on `setCompleted` / `setFailed` (BR-001 duration resolution at log moment). Never on `setDropped` (BR-005). |
| `restRunning(durationSec, startedAt, adjustmentSec)` | Timer live. Overlay shows countdown + Skip / −15s / +15s. `adjustmentSec` accumulates one-off stepper deltas (BR-002). | ← `noRest` via set log; ← `restRunning` via `setCompleted`/`setFailed` (**restart**, BR-004 — fresh `durationSec`, `adjustmentSec` reset to 0, `startedAt` = now). | → `noRest` on `skip` (BR-003). → `restExpired` on `expireNaturally` (computed moment, BR-007). → `restRunning` (re-entry) on restart. Stays `restRunning` on `adjustSec(±15)` with re-clamped remaining (BR-002). |
| `restExpired` | `startedAt + durationSec + adjustmentSec ≤ now`, overlay still in `rest` visual state. Exactly one `cue.rest.end` has been dispatched (BR-008). The set list is actionable — expiry is informational only. | ← `restRunning` via `expireNaturally`, or via `backgrounded(at:)` recompute finding an already-past expiry. | → `noRest` on `skip` (dismiss) or on any `setCompleted`/`setFailed` (which routes through `noRest`'s entry into a fresh `restRunning`). |

**Transition matrix** (rest cycle only; the overlay morph of §2b is a parallel axis):

| from \ to | restRunning | restExpired | noRest |
|---|---|---|---|
| noRest | setCompleted / setFailed (BR-001, BR-006) | `—` | setDropped (BR-005: unchanged) |
| restRunning | setCompleted / setFailed (BR-004 restart); adjustSec (same state, re-clamped) | expireNaturally; backgrounded recompute past expiry (BR-007) | skip (BR-003); adjustSec(−15) with <15s remaining ⇒ skip-equivalent (BR-002) |
| restExpired | setCompleted / setFailed (fresh timer) | backgrounded (no-op; already expired) | skip (dismiss rest-over state) |

(Dashes = illegal transition. `setDropped` from `restRunning`/`restExpired` leaves the running timer **untouched** — a dropped set is the absence of work, it neither starts nor cancels rest; BR-005 governs only that a drop never *starts* a timer.)

**Invariants**

- **INV-T1 (log-moment resolution):** the duration entering `restRunning` is resolved by the hierarchy (BR-001) **at the moment the set is logged**, using *that* set's exercise and category. A mid-rest restart picks up the new set's duration, never the old one's.
- **INV-T2 (no persistence):** `durationSec`, `startedAt`, `adjustmentSec`, and the state itself are never written to any table. The only persisted rest data is *configuration* (§3b): the four hierarchy levels.
- **INV-T3 (fire once):** `cue.rest.end` is dispatched at most once per rest run, at expiry or the first deliverable opportunity after (BR-008). Skip, restart, or morph (§2b) consume the run without a cue.
- **INV-T4 (one rule for all sets):** every `completed`/`failed` set starts rest — including the final set of an exercise and the final set of a session (BR-006). There is no between-exercises duration and no final-set exemption.
- **INV-T5 (ambient, never blocking):** rest never gates set logging. Any set may be logged at any time in any rest state; the timer adapts around the user's pace, never the reverse.
- **INV-T6 (overlay unlatch on new run):** starting a fresh run (any set log) resets the overlay to `rest` and re-latches `allSetsTerminal` from the *new* log. A finish panel from an earlier session phase can therefore never absorb a later run's rest-end cue — only the run's own terminal flag decides whether *its* expiry morphs (#10's "a normal countdown and normal cue follow" after a morph).

### 2b. Parallel overlay morph

Orthogonal to the rest cycle, the overlay's *surface* morphs when nothing actionable remains. This is #2/#10's Finish morph; this contract owns only its interaction with the rest cycle.

| Overlay state | Entered by | Exits |
|---|---|---|
| (rest cycle visible per §2a) | Default while sets remain non-terminal. | → `finishPanel` when a rest run whose logged set left **every set in the session terminal** (completed/failed/dropped) subsequently **expires or is skipped**. |
| `finishPanel` | Expiry or skip of a final-set rest run. The run is consumed **without** `cue.rest.end` — the morph *is* the cue (visual only, zero haptic, zero audio; #10 finish-morph rule). | Terminal for the session surface (#22 owns what Finish does next). |

The terminality latch is set at the set log (the caller knows session state): the final set's rest **starts exactly like every other set** (INV-T4/BR-006), counts down normally, and only its *ending* (expiry or skip) routes through the morph. Equivalently: `cue.rest.end` fires only while the overlay is in `rest` state — when the run being consumed belongs to the final terminal set, the overlay morphs instead and the morph is the entire cue (#10, verbatim).

## 3. Data Schema

Base table shapes come from #19's 0001–0003, #20's 0004 (`exercise.default_rest_sec`), #21's 0005–0006 (`routine`). **This contract creates one migration** (§3d) and no new business tables — plus a singleton settings table.

### (a) Storage locations of rest data

| Level | Field | Table/column | Owner | Written by |
|---|---|---|---|---|
| 1. Per-set | `restDurationSec?` (seconds, NULL = inherit) | `planned_set.restDurationSec` (0007) — snapshot-copied to `completed_set.plannedRestSec` at materialization (#22's seam) | this contract owns the column; #22 owns the copy | Routine editor (per-row override) |
| 2. Per-exercise | `defaultRestSec?` | `exercise.default_rest_sec` (0004, #20) | SC-exercises BR-009 | Exercise detail / library |
| 3. Per-routine | `restSec?` | `routine.restSec` (0007) | this contract | Routine settings |
| 4. Global | `defaultRestCompoundSec`, `defaultRestIsolationSec` | `app_setting` singleton rows (0007) | this contract | App settings surface (#28's consumer) |

**#20 drift note:** `exercise.default_rest_sec` is authored by `0004_exercise_library.sql`, which per `docs/MIGRATION-INTEGRATION-NOTE.md` may not have applied on databases built from #19's shape. This contract **depends** on that column existing; it does **not** re-add it (the integration rewrite of 0004 is the fix path, not a duplicate `ADD COLUMN` here). The verifier for this contract seeds the column explicitly where needed, and `0007` is written to be robust whether or not 0004 has run.

### (b) Field contracts

`?` = optional (SQL NULL). Seconds are INTEGER. Timestamps ISO-8601 UTC text; none of the *timer* fields below are persisted.

```
-- Persisted configuration (the four hierarchy levels):
PlannedSet.*   += restDurationSec: Int?          -- 0007; NULL = inherit down the chain
Exercise.*      : defaultRestSec: Int?           -- 0004 (#20); NULL = inherit
Routine.*      += restSec: Int?                  -- 0007; NULL = inherit
AppSetting      = { key: TEXT PRIMARY KEY, value: TEXT, updatedAt: TEXT }
                  rows: ('defaultRestCompoundSec', '180'), ('defaultRestIsolationSec', '90')

-- Transient, in-memory only (INV-T2; recompute source on app kill, BR-007):
RestRunning = { durationSec: Int,         -- resolved at log moment (BR-001)
                startedAt: Instant,       -- when the set was logged / timer restarted
                adjustmentSec: Int }      -- accumulated one-off ±15 deltas (BR-002), reset on restart
```

Effective remaining time, always **computed** (never ticked, never stored):

```
expiresAt   = startedAt + durationSec + adjustmentSec
remaining   = expiresAt − now            -- ≤ 0 ⇒ expired (BR-007 presents as expired)
```

### (c) Invariants

1. INV-1..INV-6 inherited unchanged from `SC-foundation@1.0.0` §3c. No exceptions.
2. **INV-S1 (additive-only settings):** `app_setting` rows are upserted by key; keys are never renamed or removed across versions, only added.
3. **INV-S2 (defaults present after migrate):** applying 0007 leaves exactly the two global default rows seeded (`180` / `90`) if absent; existing user values are never overwritten by migration.
4. **INV-S3 (clamping is a read-side rule):** the persisted config fields accept any non-negative integer a future editor writes; the ±15 live steppers and the runtime clamp to `[0, 600]`s (BR-002) — the resolution layer clamps, storage does not.

### (d) Migration `0007_rest_fields.sql`

Additive-only per INV-4. Contents:

- `ALTER TABLE planned_set ADD COLUMN restDurationSec INTEGER` — level-1 override slot (§3a). NULL = inherit.
- `ALTER TABLE routine ADD COLUMN restSec INTEGER` — level-3 override slot. NULL = inherit.
- `CREATE TABLE IF NOT EXISTS app_setting (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL, updatedAt TEXT NOT NULL)` — level-4 storage.
- `INSERT OR IGNORE INTO app_setting (key, value, updatedAt) VALUES ('defaultRestCompoundSec','180',<now>), ('defaultRestIsolationSec','90',<now>)` — INV-S2.

No `ALTER` to `exercise` (see §3a drift note). No renames, no drops, no edits to 0001–0006.

## 4. Business Rules

- **BR-001 (four-level hierarchy, first non-null wins):** at the moment a set is logged, resolve its rest duration by walking: (1) the planned set's `restDurationSec` (as snapshot-copied into the logged set), (2) the exercise's `defaultRestSec`, (3) the routine's `restSec`, (4) the global default chosen by the set's exercise category — `defaultRestCompoundSec` for `compound`, else `defaultRestIsolationSec` (isolation **and all duration-metric exercises** ride the isolation default, per #9). First non-null wins; the global defaults are always non-null after migrate (INV-S2), so resolution is total. The winning value is clamped to `[0, 600]`s (INV-S3).
- **BR-002 (one-off ±15s adjust, never persisted):** `adjustSec(+15)` / `adjustSec(−15)` accumulate onto the *running* timer's `adjustmentSec`; effective remaining recomputes from the same `startedAt`. New remaining is clamped to `[0, 600]`s. Accumulating to ≤ 0 remaining is **equivalent to skip** (BR-003). No adjust writes anything anywhere — not to the set, the exercise, the routine, or settings.
- **BR-003 (skip semantics):** `skip` cancels the timer instantly, returns the cycle to `noRest`, writes nothing, and dispatches **no** cue. From `restExpired`, skip dismisses the rest-over state to `noRest`. Skip is also the superset gesture: rest is ambient, never enforced; a skipped rest's expiry cue is simply consumed.
- **BR-004 (restart-on-completion-mid-rest):** `setCompleted` / `setFailed` while in `restRunning` or `restExpired` starts a **fresh** run: new duration resolved per BR-001 for the *new* set, `startedAt` = the new log moment, `adjustmentSec` = 0. The old run is discarded un-cued (INV-T3).
- **BR-005 (a drop never starts rest):** `setDropped` never enters `restRunning` from `noRest`, and never modifies a running/expired timer. Dropping skips work; rest follows *work*.
- **BR-006 (final-set-identical rule):** the last set of an exercise and the last set of a session follow exactly the same auto-start rule as every other set (INV-T4). When that rest then expires/is skipped with nothing terminal-remaining, §2b's morph consumes it — that, not a spared timer, is the final-set experience.
- **BR-007 (recompute-from-timestamps on kill/background):** no live daemon owns the timer. On `backgrounded(at:)` (or process relaunch, which dispatches the same recompute), remaining is recomputed as `startedAt + durationSec + adjustmentSec − now`. If positive, the run continues in `restRunning` with the recomputed remaining; if ≤ 0, the run presents as `restExpired` (cue handling per BR-008/.first-opportunity). A relaunched app with no in-memory run is simply in `noRest` — nothing about rest is recoverable from disk because nothing of rest was ever on disk (INV-T2) beyond the timestamps the caller (#22) holds.
- **BR-008 (cue-per-channel dispatch):** at expiry of a run whose overlay is still in `rest` state (not morphed, §2b), exactly one `cue.rest.end` is dispatched to the `CueDispatching` channel. The concrete fan-out — haptic `alert` pattern + one short tone + visual flip, with local-notification-class delivery for backgrounded/locked and visual+haptic-only on silenced devices (#10's five-point contract, verbatim) — is **#29's platform seam**. This contract emits the cue event into the abstract channel; delivery guarantees per channel are owned there.

## 5. API Contract

Local-only; no streams at v1. The surface exposed to #22's Active Workout money screen is a pure value-type FSM plus a dispatch seam. No GRDB appears in the FSM's surface (INV-T2).

```swift
/// The rest cycle (§2a). Pure struct, no platform imports.
struct RestCycle: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case noRest
        case restRunning(durationSec: Int, startedAt: Date, adjustmentSec: Int)
        case restExpired(durationSec: Int, startedAt: Date, adjustmentSec: Int)
    }
    /// Parallel overlay axis (§2b).
    enum Overlay: Equatable, Sendable { case rest, finishPanel }

    private(set) var state: State
    private(set) var overlay: Overlay
    /// §2b latch: set at each set log; consumed when the run ends (expire/skip).
    private(set) var allSetsTerminal: Bool
}

/// Actions dispatched into the cycle (§2a/2b). `setCompleted`/`setFailed`
/// carry the inputs BR-001 needs: the resolved config snapshot for the new set,
/// plus the session-wide terminality latch for the §2b morph.
enum RestAction: Equatable, Sendable {
    case setCompleted(resolution: RestResolution, allSetsTerminal: Bool, at: Date)
    case setFailed(resolution: RestResolution, allSetsTerminal: Bool, at: Date)
    case setDropped
    case skip(at: Date)
    case adjustSec(delta: Int, at: Date)          // ±15 in v1; contract is the delta
    case expireNaturally(at: Date)
    case backgrounded(at: Date)
}

/// The result of a BR-001 hierarchy walk, supplied by RestResolver.
struct RestResolution: Equatable, Sendable {
    var durationSec: Int            // clamped [0, 600]
    var source: RestSource          // observability only; never persisted
}
enum RestSource: String, Equatable, Sendable { case perSet, perExercise, perRoutine, globalCompound, globalIsolation }

/// The abstract cue channel (#10 taxonomy); concrete iOS delivery lands in #29.
protocol CueDispatching: Sendable {
    func dispatch(_ cue: CueEvent)
}
enum CueEvent: Equatable, Sendable {
    case restEnd                      // 'cue.rest.end' — haptic alert + tone + visual
    case finishMorph                  // 'cue.finish.morph' — visual only
}

extension RestCycle {
    var current: State { state }

    /// One transition. Returns the cue to dispatch (nil when none) — the FSM
    /// itself never touches a dispatcher; it *emits* cue events (INV-T3
    /// fire-once enforced here: a morphed or skipped run emits nothing).
    mutating func dispatch(_ action: RestAction) -> CueEvent?

    /// Seam-1→3 bridge: apply an action and route any emitted cue into the
    /// abstract channel. Concrete multi-channel delivery is #29's seam.
    mutating func dispatch<C: CueDispatching>(_ action: RestAction, into channel: C) -> CueEvent?
}

/// The hierarchy lookup (BR-001). Pure; takes the four levels as inputs so it
/// never reaches into the database mid-session.
enum RestResolver {
    static func resolve(
        perSetSec: Int?,                 // level 1
        perExerciseSec: Int?,            // level 2
        perRoutineSec: Int?,             // level 3
        categoryIsCompound: Bool,        // level-4 bucket selection
        settings: RestSettings           // level 4 values
    ) -> RestResolution
}

/// Global defaults (level 4). Value type; persisted by RestSettingsDAO.
struct RestSettings: Equatable, Sendable {
    var defaultRestCompoundSec: Int      // 180 after migrate (INV-S2)
    var defaultRestIsolationSec: Int     // 90  after migrate
}

/// GRDB-backed persistence for level-4 settings ONLY (§3a). Timer state is
/// never persisted (INV-T2) and no DAO exists for it. File: RestCycleDAO.swift.
struct RestSettingsDAO {
    init(dbQueue: DatabaseQueue)
    func fetch() throws -> RestSettings                       // post-migrate defaults guaranteed
    func update(compoundSec: Int?, isolationSec: Int?) throws // nil = leave unchanged; bumps updatedAt
}
```

**Seams under test:**
- **Seam-1 (logic):** `RestCycle.dispatch` state trajectories + `RestResolver.resolve` hierarchy — verified in a JS mirror (deterministic, platform-free) against `Tests/MooreRestTests/Fixtures/*.json`.
- **Seam-2 (persistence):** `RestSettingsDAO` round-trip + 0007 migration shape — verified at SQLite level (better-sqlite3) in the same verifier.
- **Seam-3 (cue surface):** `CueDispatching` spy receives exactly the `CueEvent`s a fixture's action sequence implies — the JS verifier mirrors dispatch collection per fixture.

## 6. UI Copy

Keyed per #6; code references keys, never literals. Voice per #17 (declarative, factual, no exclamation marks). Dynamic values use `{placeholder}`.

**Rest overlay**

| Key | String |
|---|---|
| `rest.overlay.title` | "Rest" |
| `rest.overlay.remaining` | "{mm:ss}" |
| `rest.overlay.cta.skip` | "Skip" |
| `rest.overlay.cta.plus15` | "+15s" |
| `rest.overlay.cta.minus15` | "−15s" |
| `rest.over.title` | "Rest over" |
| `rest.over.body` | "{exerciseName} — set {n} of {total}" |

**Finish morph (§2b)** — the finish panel that replaces the overlay when all sets are terminal:

| Key | String |
|---|---|
| `rest.finish.cta` | "Finish Workout" |
| `rest.finish.summary` | "{setCount} sets · {exerciseCount} exercises · {duration}" |

## 7. Acceptance Criteria

Test fixtures under `Tests/MooreRestTests/Fixtures/*.json` encode these vectors; `VerifyRest.mjs` runs them against (a) an in-memory SQLite with migrations 0001–0003, 0005–0007 applied and (b) the JS mirror of `RestCycle`/`RestResolver`/cue-spy.

| # | Setup | Action sequence | Expected | Cites |
|---|---|---|---|---|
| V1 | Session idle; levels: per-set=240 present. | `setCompleted` | `restRunning(240)`; source `perSet`; beats lower levels. | BR-001 |
| V2 | per-set absent, exercise `defaultRestSec=120`. | `setCompleted` | `restRunning(120)`; source `perExercise`. | BR-001 |
| V3 | per-set + exercise absent, routine `restSec=200`. | `setCompleted` | `restRunning(200)`; source `perRoutine`. | BR-001 |
| V4 | All overrides absent; compound exercise; settings defaults. | `setCompleted` | `restRunning(180)`; source `globalCompound`. Isolation/duration-metric exercise ⇒ `restRunning(90)`. | BR-001, #9 defaults |
| V5 | `restRunning(180)` at t=0. | `adjustSec(+15)` at t=10 | still `restRunning`, expiresAt = t+195; settings/routine/exercise/planned rows byte-identical before/after (INV-T2). | BR-002 |
| V6 | `restRunning` with 10s remaining. | `adjustSec(−15)` | cycle ⇒ `noRest` (skip-equivalent); **no** cue dispatched. | BR-002, BR-003 |
| V7 | `restRunning`. | `skip` | immediate `noRest`; no write; no cue. | BR-003 |
| V8 | `restRunning(180)` (compound set A). | `setCompleted` (isolation set B, no overrides) at t=30 | fresh `restRunning(90)`, `startedAt`=t=30, `adjustmentSec`=0; old run gone un-cued. | BR-004, INV-T1 |
| V9 | `noRest`. | `setDropped` | stays `noRest`; no timer, no cue. Also: `setDropped` mid-`restRunning` leaves the run's expiresAt untouched. | BR-005 |
| V10 | Final set of session logs. `allSetsTerminal=true`; rest running with 30s left. | `expireNaturally(at: expiry)` | overlay ⇒ `finishPanel`; `cue.finish.morph` only — **no** `cue.rest.end`, no haptic. | §2b, BR-006, #10 morph rule |
| V11 | `restRunning(180)` at t=0; app killed at t=60. | relaunch ⇒ `backgrounded(at: t=60)` then `backgrounded(at: t=200)` | at t=60: `restRunning`, remaining=120; at t=200: `restExpired`, `cue.rest.end` emitted at first deliverable opportunity (once). | BR-007, BR-008 |
| V12 | `restRunning`, overlay in `rest` state (sets remain). | `expireNaturally(at: expiry)` | exactly one `cue.rest.end` in spy, channels per #10 (haptic alert + tone + visual); no duplicate on repeated `expireNaturally`/`backgrounded`. | BR-008, INV-T3 |
| V13 | Settings table post-migrate (defaults 180/90). | `RestSettingsDAO.update(compoundSec: 150)` then `fetch` | compound=150, isolation=90; row `updatedAt` bumped; re-migrating does **not** reset the user's 150 (INV-S2, `INSERT OR IGNORE`). | §3d, INV-S2 |
| V14 | Resolution input above clamp (per-set=900). | `setCompleted` | `restRunning(600)`; clamp at resolve, storage untouched. | BR-001, INV-S3 |

Edge cases to hold: `adjustSec(+15)` repeatedly ⇒ remaining caps at 600s total; `expireNaturally` delivered twice (clock granularity) fires one cue; logging a set *after* expiry without an intervening skip starts a fresh run (no cue debt carried); a `skipped` final-set rest morphs to `finishPanel` exactly as an expired one does.

## 8. Rejected Alternatives

(Inherited verbatim from #9/#10 where marked; this contract adds none of its own.)

- **Flat single global default** → rejected (#9): wrong for heavy compounds *and* light isolation; two values preserve the 1-tap flow without configuration burden.
- **Intensity/RPE-scaled or learned "smart" rest** → rejected (#9): speculative, contradicts the strict set contract (no RPE), unbounded fog for v1.
- **Adjust-persists (shorten writes back to exercise/routine/global)** → rejected (#9 / BR-002): silent config mutation from a gym-floor gesture; writes belong in editors, not timers.
- **Persisting actual rest taken per set** → rejected (#9): violates the `weight? × reps | duration` contract; pollutes analytics with non-performance data.
- **Longer rest after the final set of an exercise** → rejected (#9 / BR-006): one rule, zero config; the Finish morph + skip cover it for free.
- **Opt-in rest, or rest only on work sets** → rejected (#9): rest is ambient and automatic.
- **Sound-only rest-end cue** → rejected (#9, re-affirmed #10): silenced/locked phones are the gym norm; haptic-first, multi-channel.
- **Haptic/audio on the Finish morph** → rejected (#10): "return to work" signal with no work remaining; the morph is its own cue.
- **Persisted timer state / live daemon surviving kill** → rejected (this contract, INV-T2 + BR-007): #9's recompute-from-timestamps rule makes a daemon unnecessary; in-memory-only keeps the dual-column invariant's world clean and the FSM testable as a pure value type.

## 9. Downstream Effects

- **Consumed by #22** (Active Workout FSM): dispatches `setCompleted`/`setFailed`/`setDropped` into `RestCycle`, supplies `RestResolver` inputs from its materialized sets, binds the overlay copy (§6), and hosts the §2b Finish morph terminal. #22 owns the wall-clock source (`at:` on every action) — this contract consumes instants, never reads time itself.
- **Feeds #7** (screen blueprint): the rest overlay's three affordances (skip, −15s, +15s), the `rest.over` visual state, and the finish panel's mini-summary format are fixed by §6.
- **Feeds #24** (progression) / **#27** (analytics): nothing — by design. No rest-taken data exists to analyze (§8, rejected persist-actual).
- **Feeds #28** (settings surface): the editable form of `RestSettings` (§5) is what a settings screen binds; defaults land via 0007 (INV-S2).
- **Feeds #29** (haptics/notifications): owns the concrete `CueDispatching` implementation — haptic `alert` + tone + visual flip in-process, local-notification-class delivery for backgrounded/locked, silenced-device degradation (BR-008, #10's five-point contract verbatim).
- **Feeds #8** (Android port): frozen at v1.0.0; the port implements from this file exact-version. Cue IDs (`cue.rest.end`, `cue.finish.morph`) are the vocabulary, not local names.
