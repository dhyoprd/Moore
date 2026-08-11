# Contract: Routine CRUD + Folders + Home Surface

```yaml
---
contractId: "SC-routines"
version: "1.0.0"
status: frozen
date: "2026-08-11"
source: "#21"
supersedes: null
supersededBy: null
---
```

Two concerns, one contract: (1) the `Routine` blueprint and its cosmetic `Folder` grouping — the user-authored plan layer; (2) the **Home surface read model** — the entry point from which every session is started. A unit tested against this contract never needs to know whether a routine was authored from scratch, duplicated from another, or reordered after an edit — those are construction details hidden by the lifecycle states below.

This contract consumes `SC-foundation@1.0.0` (schema, invariants, migrations 0001–0003) and `SC-exercises@1.0.0` (the exercise picker used by the routine editor). It adds **no** new tables; `Routine`, `Folder`, and `PlannedSet` were created by #19's migration 0001. Migration `0005_routines_folders.sql` (§3d) is additive-only and ship-only-if-missing. Migration `0006_routines_session_link.sql` (§3e) closes one schema deficit discovered during this contract: `workout_session` had no `routineId` column, which the Home derivations (`lastUsedAt`, lifecycle `draft → active`, resume-card routine name) all require; 0006 adds it additively.

## 2. State Machine

### 2a. Routine lifecycle

Every `Routine` row is in exactly one state at a time.

| State | Meaning | Entered by | Exits |
|---|---|---|---|
| `draft` | Persisted but never yet started. Legal with **zero** exercises (§7's "(#7) routines created empty are legal"); a `draft` with zero exercises has `Start` **disabled** (BR-001). | Insert from "Create routine" or from duplicate (BR-002). | → `active` on first session started from this routine. → `tombstoned` on user delete (BR-004). |
| `active` | Has been started at least once and is not tombstoned. | Auto-transition on first session materialisation (#22) — the *start* writes the transition; no user action. | → `tombstoned` on user delete (BR-004). Never returns to `draft`. |
| `tombstoned` | Row carries `deletedAt IS NOT NULL`. Not listable on Home, not startable, not editable. The row remains so any historic session/CompletedSet that names the routine still resolves its name (INV-3). | Any state via user delete (BR-004, confirm-first per §6). | → none in v1 (no un-tombstone UI per #10; row persists for history resolution). |

**Transition matrix:**

| from \ to | active | tombstoned |
|---|---|---|
| draft | first-session-start | delete-confirm |
| active | `—` | delete-confirm |
| tombstoned | `—` | `—` |

(Dashes = illegal transition.)

### 2b. Edit routine mid-session — external to session

Editing a routine is **always external to any in-flight session**. When a session is started from a routine, the routine's `PlannedSet` rows are **snapshot-copied** verbatim into that session's `plannedX` columns at materialisation (per #3's 1-tap-accept mechanism and invariant 1: `plannedWeight/plannedReps/plannedDurationSec` are frozen at session start and never drift). Therefore an edit to a routine that has an active or completed session does **not** touch the session's rows; the session keeps the plan as it was at start. There is no "live-sync from routine to open session" path, by construction.

**Invariants**

- **INV-R1:** A routine's lifecycle `draft → active` is driven by the *first session start*, never by an edit or a folder move.
- **INV-R2:** Two routines may share a name; identity is `id` (UUID) only. The "Copy of" suffix (BR-002) is cosmetic, not a uniqueness mechanism.
- **INV-R3:** Folders are cosmetic-only (#3 invariant 5). A routine is in **at most one** folder (`folderId` is 0..1). A folder delete never cascades to contained routines (BR-003).

### 2c. Folder lifecycle

| State | Meaning | Entered by | Exits |
|---|---|---|---|
| `active` | User-created grouping row, not tombstoned. | "New folder" inline on Home (#7: no folder-management screen). | → `tombstoned` on user delete (BR-004). |
| `tombstoned` | `deletedAt IS NOT NULL`. Contained routines' `folderId` is set to NULL at delete time (BR-003) — they survive at top-level unfiled. | Any state via user delete. | → none in v1. |

## 3. Data Schema

Base table shape (`routine`, `folder`, `planned_set`) comes from #19's migration 0001 — **this contract creates no tables**. §3c's migration 0005 is guarded to be a no-op when 0001 already created the tables (the normal case).

### (a) Entity table

| Entity | Role | Key relationships |
|---|---|---|
| `Routine` | Ordered blueprint for a workout | `folderId → Folder` (NULL = unfiled); owns `PlannedSet` rows by `routineId`; a session materialises from it (#22) |
| `Folder` | Flat, cosmetic grouping for routines | Parent of `Routine.folderId`; routines-only, one level deep (#3) |
| `PlannedSet` | One intended set inside a routine | `routineId → Routine`, `exerciseId → Exercise`; per-(routine, exercise) rest override slot lives on `Exercise.defaultRestSec` (SC-exercises BR-009), **not** duplicated here |
| `RoutineRow` | Not a DB entity; Home read-model row (§5) | Derived at read time from `Routine` + aggregate over its sessions (`workout_session.routineId → Routine`, added by 0006) |
| `HomeSnapshot` | Not a DB entity; Home surface bundle (§5) | `activeSession?`, `streakCount?`, `routines: [RoutineRow]`, `folders: [Folder]` |

### (b) Field contracts

`?` = optional (SQL NULL). Timestamps are ISO-8601 UTC text. All `id` are UUID strings (36-char v4, lowercase-hyphenated).

```
Routine = { id, folderId?, name, sortOrder: int, createdAt, updatedAt, deletedAt? }
Folder  = { id, name, createdAt, updatedAt, deletedAt? }

PlannedSet = { id, routineId, exerciseId, sortOrder: int,
               plannedWeight?, plannedReps?, plannedDuration?,
               setClass: warmup|work?,          -- 0002 add; NULL pre-0002, readers coalesce → 'work' (INV-6)
               createdAt, updatedAt, deletedAt? }

WorkoutSession = { id, routineId?,              -- 0006 add (see below); NULL = ad-hoc / Start-empty
                   name?, notes?,               -- 0003
                   startedAt, endedAt?,
                   importSource?, importKey?,   -- 0003
                   createdAt, updatedAt, deletedAt? }
```

`RoutineRow` (read-model; derived). Only sessions from this routine (`workout_session.routineId`) that are **completed** (`endedAt IS NOT NULL`) count toward `lastUsedAt` / last-session stats:

```
RoutineRow = { routine: Routine,
               exerciseCount: int,             -- distinct exerciseId over live PlannedSets
               lastUsedAt: string?,            -- MAX(startedAt) over this routine's completed sessions; NULL if never
               lastSessionSetCount: int?,      -- completed sets in that session
               lastSessionVolumeKg: double?,   -- Σ(actualWeight × actualReps), completed work sets only
               lastSessionDescription: string?,-- formatted "{setCount} sets · {volumeKg} kg"; NULL when never used
               startEnabled: bool }            -- = exerciseCount > 0  (BR-001)
```

`HomeSnapshot` (read-model; derived):

```
HomeSnapshot = { activeSession: { id, routineId?, routineName?, startedAt, setsDone, setsTotal }?,
                 streakCount: int?,           -- nil when zero completed sessions (BR-005); else ≥1
                 routines: [RoutineRow],      -- last-used desc, then name asc (BR-006)
                 folders: [Folder] }          -- live folders, name asc
```

### (c) Invariants + derivation

1. **INV-1 (UUID identity), INV-2 (timestamps/LWW), INV-3 (tombstone), INV-4 (additive-only), INV-5 (dual planned/actual), INV-6 (warmup class)** — inherited unchanged from `SC-foundation@1.0.0` §3c. This contract adds no exceptions.
2. **INV-R4 (no derived persistence):** `RoutineRow` and `HomeReadModel` are **read-time** derivations only (#3 invariant 5: analytics never persists). No `lastUsedAt`, `exerciseCount`, `streakCount`, or volume column is ever stored. Home recomputes on every `readModel()` call.
3. **INV-R5 (snapshot independence):** a routine's edit history is invisible to sessions started before that edit (§2b). Editing is safe precisely because the copy happened at start.

### (d) Migration `0005_routines_folders.sql`

Additive-only per INV-4 / `SC-foundation` BR-001. Applies `CREATE TABLE IF NOT EXISTS` for `folder` / `routine` / `planned_set` with the 0001 shapes, so a database built without 0001 (not the case here, but the guard keeps the file lawfully re-runnable) still gains the tables. Adds an index on `routine(folderId)` for the Home grouping query. **Performs no `ALTER` to those tables, no rename, no drop.**

### (e) Migration `0006_routines_session_link.sql` — schema deficit

Discovered while landing this contract: `SC-foundation` migration 0001 created `workout_session` **without** a `routineId` column, yet the Home derivations that are this contract's reason to exist — `RoutineRow.lastUsedAt`, the lifecycle `draft → active` transition, the resume card's routine name — all require knowing which routine a session was started from. Ad-hoc "Start empty" sessions have no routine. Additive-only per INV-4:

- `ALTER TABLE workout_session ADD COLUMN routineId TEXT REFERENCES routine(id)` — **nullable**, NULL = ad-hoc / Start-empty session.
- `CREATE INDEX workout_session_routine_idx ON workout_session(routineId) WHERE deletedAt IS NULL` — serves the per-routine `lastUsedAt`/last-session-stats aggregate.

No edit to 0001–0005; this is a new migration only.

## 4. Business Rules

- **BR-001 (zero-exercise routine cannot start):** `RoutineRow.startEnabled = exerciseCount > 0`. The Home `Start` CTA on a routine row is disabled when the routine has zero live `PlannedSet` rows. This is structural, not navigational (#14 §2): the always-visible `Start empty` is the path to an empty session; routine `Start` implies a plan exists. Disabled state uses copy (§6), never a toast.
- **BR-002 (duplicate is a true copy):** duplicating a routine inserts a **new** `Routine` row with a fresh UUID `id`, `name = "Copy of " + source.name`, `folderId` copied verbatim, and a full deep copy of every live `PlannedSet` (new `PlannedSet.id`s, same `sortOrder`/`exerciseId`/`plannedX`/`setClass`), all in one transaction. The copy enters lifecycle as `draft` regardless of the source's state.
- **BR-003 (folder delete leaves routines unfiled):** deleting a folder (BR-004 confirm-first) sets every contained routine's `folderId = NULL` and tombstones the folder, in one transaction. No routine is tombstoned, moved to another folder, or reordered as a side effect.
- **BR-004 (confirm-first destructive):** the three destructive actions — **delete routine**, **delete folder**, **discard session** — each require a `cue.confirm.destructive` modal before the write (#10 §destructive). The confirm copy lives in §6. The write itself is a tombstone (INV-3); there is no hard DELETE at the DAO layer (`SC-foundation` BR-003).
- **BR-005 (streak chip visibility + rounding):** the streak chip is **hidden** (`streakCount = nil`) when zero completed `WorkoutSession`s exist. With ≥1 completed session, the chip shows the count of consecutive calendar weeks — ending at the current week — that each contain ≥1 completed session. **Rounding rule:** a week counts toward the streak if it has ≥1 completed session even when that week is not yet over (the current week rounds *up* into the count); a streak of exactly one prior full week plus the current partial week therefore reads `2`, not `1`. Display string is §6 `home.streak_label`. (Derived, never persisted, per INV-R4.)
- **BR-006 (home ordering):** the flat routine list orders by `lastUsedAt DESC` (most-recent first), ties and never-started routines (`lastUsedAt IS NULL`) fall back to `name ASC`. Folders render in `name ASC`; within a folder the same last-used-desc/name rule applies. The "Unfiled" pseudo-group (§6 `home.unfiled_header`) renders last, after every real folder.

## 5. API Contract

Local-only; no streams at v1 (sync seam is `SC-foundation` §5). The Home surface exposes exactly one read seam and the routine/folder mutations are plain typed DAO calls exercised at seam-2.

**Home read model** — the value-type bundle the Home screen binds to:

```swift
protocol HomeSurfaceReading {
    func readModel() throws -> HomeSnapshot
}
```

- `readModel()` is the **only** read the Home screen performs. It returns a fully materialised `HomeSnapshot` (§3b): `activeSession` populated iff a `WorkoutSession` with `endedAt IS NULL` exists; `streakCount` per BR-005; `routines` per BR-006; `folders` per BR-006.
- **Write seam (typed DAO, not on `HomeSurfaceReading`):** `RoutineDAO.create / updateSets / duplicate / tombstone`, `FolderDAO.create / rename / tombstone / moveRoutine`. Every write follows `SC-foundation` BR-003 (tombstone, bump `updatedAt`).
- **No write enters through the read model.** The Home screen never mutates; it calls the DAOs and re-invokes `readModel()`.

## 6. UI Copy

Keyed per #6; code references keys, never literals. Voice per #17 (declarative, no exclamation marks, factual). Dynamic values use `{placeholder}`.

**Home surface**

| Key | String |
|---|---|
| `home.empty_title` | "No routines yet" |
| `home.empty_sub` | "Routines are your gym days. Create one and your next workout is one tap to start." |
| `home.empty_cta` | "Create your first routine" |
| `home.streak_label` | "{n}-day streak" |
| `home.startEmpty_cta` | "Start empty" |
| `home.resume_label` | "Resume: {routineName} — {setsDone}/{setsTotal} sets" |
| `home.resume_cta` | "Resume" |
| `home.routineRow_title` | "{name}" |
| `home.routineRow_sub` | "{count} exercises" |
| `home.routineRow_lastUsed` | "{relativeDate} · {setCount} sets · {volumeKg} kg" |
| `home.routineRow_start` | "Start" |
| `home.unfiled_header` | "Unfiled" |
| `home.newRoutine_fab` | "Routine" |

**Routine editor**

| Key | String |
|---|---|
| `routineEditor.new_title` | "New routine" |
| `routineEditor.edit_title` | "Edit routine" |
| `routineEditor.namePlaceholder` | "e.g. Push Day A" |
| `routineEditor.addExercise_cta` | "Add exercise" |
| `routineEditor.setColumnWeight` | "Weight" |
| `routineEditor.setColumnReps` | "Reps" |
| `routineEditor.setColumnDuration` | "Duration" |
| `routineEditor.save_cta` | "Save" |
| `routineEditor.startDisabled_hint` | "Add an exercise ahead of starting" |

**Confirm-first destructive (#10 / §6, BR-004)**

| Key | String |
|---|---|
| `confirm.deleteRoutine.title` | "Delete "{name}"?" |
| `confirm.deleteRoutine.body` | "Its history stays. This routine won't show on Home." |
| `confirm.deleteRoutine.confirm` | "Delete" |
| `confirm.deleteRoutine.cancel` | "Cancel" |
| `confirm.deleteFolder.title` | "Delete "{name}"?" |
| `confirm.deleteFolder.body` | "Routines inside move to Unfiled. Nothing is lost." |
| `confirm.deleteFolder.confirm` | "Delete" |
| `confirm.deleteFolder.cancel` | "Cancel" |
| `confirm.discardSession.title` | "Discard workout?" |
| `confirm.discardSession.body` | "No sets logged" |
| `confirm.discardSession.confirm` | "Discard" |
| `confirm.discardSession.cancel` | "Keep" |

## 7. Acceptance Criteria

Test fixtures under `Tests/MooreRoutinesTests/Fixtures/*.json` line up with these vectors; the Node verifier `VerifyRoutines.mjs` runs them against an in-memory SQLite with 0001–0005 applied.

| # | Setup | Action | Expected | Cites |
|---|---|---|---|---|
| V1 | No routines exist. | `RoutineDAO.create` with name + exercise list (each with ≥1 set row). | New `Routine` persisted with fresh UUID; `PlannedSet` rows linked; Home `readModel().routines` contains it. | §2a, INV-1 |
| V2 | Routine with 3 sets exists. | Edit: reorder sets, add an exercise, change one `plannedWeight`. Re-fetch. | New values round-trip intact; `updatedAt` bumped; `createdAt` unchanged (INV-2). | INV-2, §2a |
| V3 | Routine "Push Day A" (1 exercise, 2 sets) exists. | `RoutineDAO.duplicate`. | New routine, `name = "Copy of Push Day A"`, new `id`, same `folderId`, 2 sets copied with new ids; source unchanged. | BR-002 |
| V4 | Routine "Push Day A" exists. | Delete with confirm-first (BR-004). | Routine tombstoned (`deletedAt` set), not hard-deleted; absent from `readModel().routines`; present in including-tombstoned scan. | BR-004, INV-3 |
| V5 | Folder "Legs" containing 2 routines exists. | `FolderDAO.tombstone`. | Folder tombstoned; both routines read back with `folderId = NULL` under the Unfiled group. | BR-003, INV-R3 |
| V6 | Routine with **zero** exercises exists. | `readModel()`. | Its `RoutineRow.startEnabled = false`; `home.startEmpty_cta` remains the only empty-session path. | BR-001 |
| V7 | No sessions exist. | `readModel()`. | `streakCount = nil` (chip hidden); `activeSession = nil`; empty-state keys (§6) are what the surface binds. | BR-005 |
| V8 | 12 routines across 3 folders exist (fixture `populated-home.json`). | `readModel()`. | 3 folders + Unfiled group; within each group routines ordered last-used desc; 20+-routine render path constructs without error. | BR-006 |
| V9 | Exactly 1 completed session exists (current week). | `readModel()`. | `streakCount = 1`; chip visible per §6 `home.streak_label` with `n = 1`. | BR-005 |
| V10 | Completed sessions in each of the last 2 weeks, none this week, then 1 today. | `readModel()`. | `streakCount = 3` — the current partial week rounds up into the count. | BR-005 (rounding) |
| V11 | Routine with an active session started from it. | Edit the routine (§2b). | The session's `plannedX` values are unchanged; routine edit is external to the session. | §2b, INV-R5 |
| V12 | Round-trip `Routine` + `Folder` + `PlannedSet` (insert → select by id). | — | Field-for-field equality incl. NULL `folderId` / `deletedAt` preserved. Seam-2 round-trip. | INV-1, INV-3, INV-4 |

Edge cases to hold: duplicating a `draft` zero-exercise routine produces a `draft` zero-exercise copy with `startEnabled = false`; deleting the last folder leaves every surviving routine under Unfiled with no reordering; renaming a folder does not touch its routines' `updatedAt`.

## 8. Rejected Alternatives

- **Hard-delete routines/folders** → rejected: INV-3 and #3 invariant 2 (historic sessions must resolve names); tombstones are the only delete.
- **Nested folders** → rejected: #3 rejects general nesting — flat, routines-only, cosmetic. One level deep, zero behavioural effect.
- **Cascading folder delete to contained routines** → rejected: #3 invariant 5 / BR-003 — contents survive at top-level unfiled; losing user-authored blueprints on a cosmetic-organisation delete is unacceptable.
- **Persisting `lastUsedAt` / `exerciseCount` / `streakCount` on the Routine row** → rejected: #3 invariant 5 / INV-R4 — derived, never persisted; a stored cache can drift from `CompletedSet`.
- **A `Template` entity separate from `Routine`** → rejected: #3 collapses these; a `Routine` *is* the blueprint. (`SC-foundation` §8 carries the same rejection.)
- **Live-syncing an open session when its routine is edited** → rejected: §2b / INV-R5 — the snapshot-copy at start is the load-bearing invariant; re-deriving mid-session would break plan-vs-actual deltas and the 1-tap-accept contract.
- **Showing a 0-day streak chip** → rejected: #14 §1 — honest visibility beats motivational theatre; the chip is hidden until the first completed session.

## 9. Downstream Effects

- **Unblocks #22** (Active Workout FSM): consumes `PlannedSet` snapshot-copy on session start (§2b); reads `activeSession` from the same `WorkoutSession` rows Home's resume card reads.
- **Feeds #23** (rest logic): per-(routine, exercise) rest override resolves through the routine editor's slot; the override *value* lives on `Exercise.defaultRestSec` (SC-exercises BR-009), this contract owns the editor surface that writes it.
- **Feeds #24** (progression): reads `Routine`/`PlannedSet` shapes; progression suggestions derive at read per INV-R4, never from a stored routine field.
- **Feeds #27** (analytics): the streak chip and adherence header reuse BR-005's consecutive-weeks derivation.
- **Feeds #8** (Android port): frozen at v1.0.0; the port implements from this file exact-version. UI copy keys (§6) carry tone per #17 and must survive verbatim.
