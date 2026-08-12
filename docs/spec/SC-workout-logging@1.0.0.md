# Contract: Active Workout FSM — Session Logging

```yaml
---
contractId: "SC-workout-logging"
version: "1.0.0"
status: frozen
date: "2026-08-12"
source: "#22"
supersedes: null
supersededBy: null
---
```

The Active Workout money screen: a flat, order-free list of set rows, every row independently actionable, no enforced "current set" cursor. Editing is transient UI (a bottom sheet), never an FSM state. This contract consumes `SC-foundation@1.0.0` (schema), `SC-routines@1.0.0` (the routine a session materialises from), and #10's cue taxonomy (this layer **emits cue descriptors, never drives haptics/audio**). It adds **no** new tables and **no** new migrations.

**Rest timer boundary:** rest logic (durations, resolution, timers, skip/shorten, restart-on-superset) belongs to #23's layer. This contract only *requests* rest: when a set reaches `completed` or `failed` from `planned`, the FSM sets `overlayState = restRequested` and emits `cue.set.completed` / `cue.set.failed`. How, whether, and how long the overlay counts down is #23's business, not this FSM's.

## 2. State Machine

### 2a. Per-set states

Every `CompletedSet` row in the active session is in exactly one state of its `status` column.

| State | Meaning | Entered by | Exits |
|---|---|---|---|
| `planned` | Materialised at session start (or added mid-session); `actualX` NULL; accepts planned values in one tap | Session start materialisation; `[+]` add-set (BR-004); undo-drop (BR-003) | `accept` → `completed`; `editAndAccept` → `completed`; `fail` → `failed`; `drop` → `dropped` |
| `completed` | Logged with actual values (`actualX` non-NULL) | `accept` field-copy (BR-001); `editAndAccept` (BR-001) | `editCompleted` (overwrite in place, stays `completed`, BR-006) |
| `failed` | Attempted but missed target — **actual reps hit are recorded** (never zero-data; auto reps-minus-one writes fiction) | `fail` with explicit actuals (BR-002) | `editFailed` (overwrite in place, stays `failed`, BR-006) |
| `dropped` | Deliberately skipped; no actuals; excluded from volume and progression | `drop` from `planned` only | `undoDrop` → `planned`, while the undo window is open (BR-003) |

**Transition & affordance matrix** (`—` = *illegal action*: the FSM returns an error, changes nothing, emits nothing, and never crashes the money screen):

| from \ action | accept | editAndAccept | fail | editCompleted | editFailed | drop | undoDrop |
|---|---|---|---|---|---|---|---|
| planned | → completed, rest requested | → completed, rest requested | → failed, rest requested | `—` | `—` | → dropped | `—` |
| completed | `—` | `—` | `—` | overwrite, **no** rest | `—` | `—` | `—` |
| failed | `—` | `—` | `—` | `—` | overwrite, **no** rest | `—` | `—` |
| dropped | `—` | `—` | `—` | `—` | `—` | `—` | → planned (window open) / `—` (window closed) |

There is no transition from `completed` or `failed` back to `planned`, and no transition out of `completed`/`failed` into `failed`/`completed` respectively (a deliberately re-failed set is `editFailed` with new actuals — the status stays; the FSM never erases that a set was logged).

### 2b. Session overlay states

The session carries exactly one overlay state at a time. **This FSM owns only the transition into `restRequested` and into `finishRequested`; the countdown, expiry, skip/shorten, and restart semantics of the rest overlay itself are #23.**

| State | Meaning | Entered by | Exits |
|---|---|---|---|
| `idle` | No rest outstanding. (This is also the superset path: logging exercise B after exercise A is just a transition into `restRequested` again — BR-007.) | Session start; every `undoDrop` / `drop` (dropped sets never request rest, BR-008); #23's layer clears | Any set `planned → completed/failed`: → `restRequested` |
| `restRequested` | A set completion/failure has just been logged and rest has been **requested** (`cue.set.completed`/`cue.set.failed` emitted, `nextIncomplete` set row highlighted by #23). | `accept` / `editAndAccept` / `fail` from `planned` | #23's layer (skip/expiry/restart) returns to `idle`; or `finishRequested` takes over when the last set goes terminal (BR-008) |
| `finishRequested` | Every set is terminal (`completed`/`failed`/`dropped`): the money screen's CTA morphs into **Finish Workout** (`cue.finish.morph` emitted once per session). One tap → `finishSession` → session `completed`, `endedAt` stamped. | The action that flips the last non-terminal set terminal | `finishSession` → session leaves the FSM's scope (summary screen, #22 sibling surface) |

**Invariants**

- **INV-W1 (no current-set cursor):** "next up" is a *derived* highlight — the first non-terminal row — never an FSM-enforced turn order. Any row may be acted on at any time; order-free logging is lawful (Seam-3 AC).
- **INV-W2 (actuals NULL iff `planned`):** `dropped` sets have NULL actuals and are excluded from volume/progression; `completed`/`failed` always carry actuals (BR-002's fail-records-actuals; SC-foundation BR-004's lawful-NULL).
- **INV-W3 (materialised snapshot):** `plannedX` at session start copy the routine's `PlannedSet.plannedX` verbatim (SC-foundation INV-5); they are immutable for the session's life (INV-R5).
- **INV-W4 (one finish morph):** `cue.finish.morph` is emitted at most once per session — on the transition into `finishRequested`, not on every subsequent action.
- **INV-W5 (rest is a request, not a timer):** this layer never starts, counts, or cancels a timer. It only flips `overlayState` and emits cues. `restRequested: true` in the snapshot is the *entire* contract with #23.

## 3. Data Schema

**(a) Entity table** — this contract creates **no** tables. `workout_session` and `completed_set` exist since `SC-foundation` migration 0001; `workout_session.routineId` since `SC-routines` migration 0006.

| Entity | Role | Key relationships |
|---|---|---|
| `WorkoutSession` | One gym visit in progress | `routineId → Routine` (NULL = ad-hoc Start-empty); owns `CompletedSet` rows |
| `CompletedSet` | One set row on the money screen | `sessionId → WorkoutSession`, `exerciseId → Exercise`; dual planned/actual columns |
| `StateSnapshot` | Not a DB entity; the FSM's observable read-only state | Derived from the session's `CompletedSet` rows at every read |

**(b) Field contracts** (`?` = optional / SQL NULL; timestamps ISO-8601 UTC; ids UUID strings)

```
WorkoutSession = { id, routineId?, name?, notes?, startedAt, endedAt?,
                   importSource?, importKey?, createdAt, updatedAt, deletedAt? }
                 -- contract addition: status is derived at read — endedAt IS NULL ⇔ active.

CompletedSet   = { id, sessionId, exerciseId, sortOrder: int,
                   plannedWeight?, plannedReps?, plannedDuration?,
                   actualWeight?, actualReps?, actualDuration?,
                   status: planned|completed|failed|dropped,
                   setClass: warmup|work?,          -- 0002; NULL → 'work' (INV-6)
                   completedAt?,                    -- set when status leaves 'planned'
                   createdAt, updatedAt, deletedAt? }
```

**(c) Invariants + derivation** — INV-1…INV-7 inherited unchanged from `SC-foundation §3c`; INV-R5 (`SC-routines §2b`) holds for the materialised copy. Additions:

1. **INV-W6 (completedAt is append-only):** `completedAt` stamps the moment `status` first leaves `planned`; `editCompleted`/`editFailed` bump `updatedAt` but never `completedAt`.
2. **INV-W7 (sortOrder contiguity per session):** `sortOrder` is per-`sessionId`, zero-based, contiguous (SC-foundation BR-005). `[+]` appends at `count`, never inserts mid-list.
3. **INV-W8 (session end matches finish):** `endedAt` is set exactly once, by `finishSession`; a session with `endedAt` is `completed` lifecycle and leaves `readModel().activeSession` on Home (`SC-routines §3b`).

**(d) Migration: none.** Foundation 0001 created `completed_set` with `status TEXT NOT NULL CHECK (status IN ('planned','completed','failed','dropped'))` and the full dual planned/actual column family; 0002 added `setClass`; 0006 added `workout_session.routineId`. This contract was audited against `Sources/MooreFoundation/Migrations/0001_core.sql` — no true deficit exists (see `docs/MIGRATION-INTEGRATION-NOTE.md`, resolved separately; this contract stays additive). Had a deficit existed, the next free identifier would be `0008_*` — `0007_*` is #23's — but none was needed.

## 4. Business Rules

- **BR-001 (1-tap accept field-copy):** ✓ on a `planned` row sets `actualX = plannedX` **field-by-field** (weight, reps, duration — whichever are non-NULL) and flips `status → completed`, in the same write. Zero data loss by construction: planned and actuals live in separate columns forever (SC-foundation INV-5). The edited variant (`editAndAccept` after the bottom sheet) writes the user-adjusted values into `actualX` instead of copying — `plannedX` still untouched. Both variants request rest (overlay → `restRequested`, cue `cue.set.completed`).
- **BR-002 (fail flow records actual reps):** swipe-left → Failed → sheet pre-tagged `failed`, weight pre-filled from `plannedWeight`, reps focused → user types the actual count → ✓. `fail` requires explicit `actualX`; failing at 7 vs 4 carries opposite progression signals (hold vs deload), so zero-data failure was rejected (#2). Flips `status → failed`, stamps `completedAt`, requests rest (`cue.set.failed`). A failed set never writes PR rows (downstream #26 / #10).
- **BR-003 (drop + undo until next set logged — no timer):** swipe-left → Drop set is instant: `status → dropped`, no actuals, **no rest requested** (INV-W5; cue `cue.set.dropped`). The undo toolbar appears and lives **until the next set is logged — any set, any exercise — with no timer** (#10). Any terminal transition (`accept`/`editAndAccept`/`fail`) on any row closes the window; `undoDrop` re-opens the row to `planned` and clears the undo record, only while the window is open.
- **BR-004 (add-set pre-filled from last row):** `[+]` in an exercise-group header appends a new `planned` row to the session (`sortOrder = session count`, INV-W7), pre-filled from **that exercise's last row in the session**: `plannedX` copied verbatim, `actualX` NULL, `setClass` inherited. Dropsets are emergent (#2): add a row, edit weight down in the sheet, ✓. Adding a set never requests rest.
- **BR-005 (mis-tap-proof — no row steppers):** per-set ✓ hit target ≥ 44×44pt, and rows carry **no inline steppers** — the 80% path (planned → completed) is single-tap and cannot accidentally mutate a value. Editing is exclusively the bottom-sheet path (3 taps for the 20% case).
- **BR-006 (edit-after-complete never re-triggers rest):** editing a `completed` set overwrites `actualX` in place (INV-W6: `completedAt` intact) and emits **no** rest request, **no** `cue.set.completed` — post-completion edits are corrections, not new events (#3 invariant 2: edits post-completion do not re-trigger rest). The same holds for editing a `failed` set (`editFailed`). Rest is requested only by the `planned → completed/failed` transition.
- **BR-007 (superset is modeless):** two exercises' rows interleaved need no mode: each row accepts independently; interleaving exercises is lawful at all times; `nextIncomplete` reading for #23 is always the first non-terminal row regardless of exercise. Completing exercise B mid-"rest-for-A" is identical in FSM terms to any other transition; #23's layer owns the timer-skip semantics.
- **BR-008 (finish-morph trigger):** the moment every set in the session is terminal (`status ∈ {completed, failed, dropped}`), the overlay enters `finishRequested` and the FSM emits `cue.finish.morph` exactly once (INV-W4). Dropped sets count as terminal for this check but never request rest themselves. Session `finishSession` stamps `endedAt` and is the only writer of it (INV-W8).

## 5. API Contract

Local-only. Pure value-type FSM at seam-1 (no DB, Foundation only); GRDB DAO at seam-2; the UI binds to the FSM's snapshot.

```swift
public enum FsmAction { /* §2a actions, parameterised; see Models.swift */ }

public protocol WorkoutSessionFSMing {
    /// Dispatch an action. Illegal actions (§2a's `—` cells) return
    /// `TransitionResult.failure(reason)`; state is unchanged. No throws.
    mutating func dispatch(_ action: FsmAction) -> TransitionResult

    /// Read-only observable snapshot for the money screen's render pass.
    var state: StateSnapshot { get }
}

public protocol ActiveWorkoutReading {
    /// The money screen's only read: derived set rows (grouped exercise order
    /// preserved by sortOrder), first-incomplete highlight, overlay state.
    func readModel() throws -> ActiveWorkoutSnapshot
}
```

- `dispatch(_:)` is the **single entry point** for every user gesture on the money screen (✓, sheet ✓, swipe-left failed, swipe-left drop, undo, `[+]`, finish). There is no write path around the FSM; the DAO is only ever called *by* the FSM's persistence adapter (seam-2), so the money screen can never desync from the log.
- `state` is a value-type `StateSnapshot`: `sets: [SetSnapshot]` (id, exerciseId, sortOrder, status, planned/actual values), `overlayState: idle|restRequested|finishRequested`, `lastCompletedSetId?`, `restRequested: Bool`, `nextIncompleteSetId?`, `undoableDrop: { setId, available: Bool }?`, `finishReady: Bool`.
- `readModel()` (seam-2) materialises the same shape from SQLite for a cold render (app relaunch mid-session per #9 rule 4's spirit: state recomputed from rows, never from a daemon).
- Cues are **emitted, not performed**: `TransitionResult` carries `[CueEmission]` (`cue.set.completed`, `cue.set.failed`, `cue.set.dropped`, `cue.finish.morph`); #23 / #29's cue dispatcher consumes them. This layer imports no haptic framework.
- `Materialize.startSession(routineId:)` copies the routine's live `PlannedSet`s → `CompletedSet`s (`plannedX` verbatim, `actualX` NULL, `status = 'planned'`, contiguous `sortOrder`) and creates the `WorkoutSession` row, in one transaction. Ad-hoc sessions (`routineId = nil`) materialise with zero rows.

## 6. UI Copy

Keyed per #6; code references keys, never literals. Voice per #17 (declarative, no exclamation marks). Dynamic values use `{placeholder}`.

| Key | String |
|---|---|
| `workout.title` | "{routineName}" |
| `workout.adhoc_title` | "Workout" |
| `workout.section.nextUp` | "Next up" |
| `workout.set.plannedValue` | "{weight} × {reps}" |
| `workout.set.durationValue` | "{duration}" |
| `workout.set.doneDelta` | "{actualWeight} × {actualReps}" |
| `workout.set.failedDelta` | "Failed at {actualReps} — {plannedWeight} × {plannedReps}" |
| `workout.set.dropped` | "Set dropped" |
| `workout.set.acceptHint` | "Tap ✓ to log" |
| `workout.edit.title` | "Edit set" |
| `workout.edit.failTitle` | "Failed set" |
| `workout.edit.weightLabel` | "Weight" |
| `workout.edit.repsLabel` | "Reps" |
| `workout.edit.durationLabel` | "Duration" |
| `workout.edit.actualRepsPlaceholder` | "Reps completed" |
| `workout.edit.accept` | "Done" |
| `workout.addSet.cta` | "+" |
| `workout.undo.title` | "Set dropped" |
| `workout.undo.cta` | "Undo" |
| `workout.finish.title` | "Workout complete" |
| `workout.finish.subtitle` | "{setsDone} sets · {volumeKg} kg" |
| `workout.finish.cta` | "Finish workout" |
| `workout.empty.title` | "No sets yet" |
| `workout.empty.sub` | "Add an exercise to start logging." |
| `confirm.discardSession.title` | "Discard workout?" |
| `confirm.discardSession.body` | "{setsLogged} sets logged. This can't be undone." |
| `confirm.discardSession.confirm` | "Discard" |
| `confirm.discardSession.cancel` | "Keep" |

## 7. Acceptance Criteria

Fixtures under `Tests/MooreWorkoutTests/Fixtures/*.json`, one per AC; the Node verifier `VerifyWorkoutFsm.mjs` applies migrations to a fresh in-memory DB per fixture, runs each scenario's action list through a JS mirror of the FSM, and asserts resulting DB rows + snapshot fields.

| # | Setup | Action | Expected | Cites |
|---|---|---|---|---|
| V1 | Routine (2 exercises, 3 planned sets) exists | Materialise session from routine | `WorkoutSession` created (`routineId` linked); 3 `CompletedSet` rows: `plannedX` = routine values, `actualX` NULL, `status = 'planned'`, contiguous `sortOrder` 0-2 | §5, INV-W3, INV-W7 |
| V2 | Session with a `planned` set (weight 60 × 8) | `accept(setId)` | `status = completed`; `actualWeight = 60, actualReps = 8` (field-copy); `completedAt` stamped; snapshot `overlayState = restRequested`, `lastCompletedSetId = setId`, emitted cue `cue.set.completed` | BR-001, §2b |
| V3 | Same `planned` set, via sheet | `editAndAccept(setId, weight: 65, reps: 8)` | `actualWeight = 65`; `plannedWeight = 60` untouched (INV-W3); `status = completed`; rest requested | BR-001 |
| V4 | `planned` set (weight 60 × 8) | `fail(setId, weight: 60, reps: 7)` | `status = failed`; `actualWeight = 60, actualReps = 7` recorded explicitly; rest requested; no PR row touched (downstream) | BR-002 |
| V5 | Two `planned` sets A, B | `drop(A)` → `undoDrop(A)` | A: `dropped` (no actuals, **no** `restRequested`); undo record available; undo restores A to `planned`, `actualX` NULL | BR-003, BR-008 |
| V6 | A dropped, B planned | `drop(A)` → `accept(B)` → `undoDrop(A)` | Undo on A **refused** (window closed by next logged set); A stays `dropped`; B `completed` | BR-003 |
| V7 | Exercise E has a logged set (or last `planned` row) weight 60 × 8 | `addSet(exerciseId: E)` | New `planned` row appended at `sortOrder = count`, `plannedWeight = 60, plannedReps = 8` pre-filled from E's last row, `actualX` NULL; no rest requested | BR-004, INV-W7 |
| V8 | Set `completed` (via accept) | `editCompleted(setId, reps: 10)` | `actualReps = 10`; `status` stays `completed`; `completedAt` unchanged (INV-W6); `updatedAt` bumped; **no** rest requested, no `cue.set.completed` re-emitted | BR-006 |
| V9 | Sets A(ex1), B(ex2), C(ex1) planned | `accept(B)` → `accept(A)` → `accept(C)` | All three `completed` with field-copied actuals **regardless of order**; `nextIncompleteSetId` nil after last; order-free logging holds | INV-W1, BR-007 |
| V10 | Sets A, B planned | `drop(A)` → `accept(B)` | A `dropped`, B `completed`; `finishReady = true`; `overlayState = finishRequested`; `cue.finish.morph` emitted exactly once (INV-W4); A requested no rest | BR-008 |
| V11 | Set A `planned` | `drop(A)` → `undoDrop(A)` → `accept(A)` | Undo re-opens; accept afterwards normal: A `completed`, rest requested once | BR-003 |
| V12 | Session with all sets terminal | `finishSession()` | `endedAt` stamped exactly once; `readModel().activeSession` on Home no longer lists it; snapshot out of FSM scope | BR-008, INV-W8 |

Edge cases to hold: illegal actions (§2a `—` cells) return descriptive failure with zero state change and zero cues; `accept` twice on the same row is illegal (second returns failure, values intact); `undoDrop` on a row never dropped is illegal; duration-only sets copy `actualDuration` from `plannedDuration` on accept (BR-001 field-copy covers whichever fields are non-NULL).

## 8. Rejected Alternatives

Drop-undo as a 10 s snackbar → rejected (#10): expires mid-rest, silently making a reversible gesture irreversible; undo lives until the next set is logged, no timer. Rest as an opt-in state → rejected: rest is ambient, automatic on completion (#2). Inline steppers on rows → rejected: mis-tap risk on the 80% path (BR-005). Long-press / sheet-buried failed-drop → rejected: swipe-left is one fluid gesture. Failed = zero data, or auto reps-minus-one → rejected: starves progression and writes fiction into the log (#2; BR-002). Current-set cursor enforcement → rejected: kills superset emergence, forces linear order (#2). Storing FSM state (`overlayState`, rest flags) in SQLite → rejected: state recomputes from `CompletedSet` rows (this contract owns no new columns); a stored FSM cache could drift from the log. Persisting the undo window as a timestamp → rejected: #10 forbids a timer; the window is session-logic, derived from "has any set gone terminal since this drop".

## 9. Downstream Effects

- **Unblocks #23** (rest cues): consumes exactly `overlayState = restRequested` transitions, `nextIncompleteSetId`, and `cue.set.completed` / `cue.set.failed` emissions; owns everything the timer counts down from.
- **Feeds #24** (progression): reads `plannedX` vs `actualX` — including failed-with-actual-reps rows (BR-002) — off `CompletedSet`; dropped rows excluded (INV-W2).
- **Feeds #26** (PRs): PR re-derivation runs on rows this FSM flips to `completed`; failed sets never write PR rows.
- **Feeds #27** (analytics): volume queries read `actualX` over non-dropped rows; adherence compares `plannedX` vs `actualX` (INV-W3).
- **Feeds #29** (haptic drivers): this FSM emits cue descriptors only; #29 owns the drivers.
- **Feeds #8** (Android port): frozen at v1.0.0; the port implements from this file exact-version. UI copy keys (§6) carry tone per #17 and must survive verbatim.
