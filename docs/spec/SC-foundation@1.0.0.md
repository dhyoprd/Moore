# Contract: SQLite Foundation — Storage Layer

```yaml
---
contractId: "SC-foundation"
version: "1.0.0"
status: frozen
date: "2026-08-11"
source: "#19"
supersedes: null
supersededBy: null
---
```

The single on-device store every other Moore module reads and writes through. Nine entities, three numbered migrations, one additive-only rule, field-level LWW pre-computed at the schema level. Zero network, zero UI, zero business logic beyond shape.

## 2. State Machine

None for this contract.

## 3. Data Schema

**(a) Entity table**

| Entity | Role | Key relationships |
|---|---|---|
| `Exercise` | Canonical movement a user performs (bench, squat, …) | `primaryMuscleId → MuscleGroup` (NULL = unclassified); consumed by `PlannedSet.exerciseId`, `CompletedSet.exerciseId`, `PersonalRecord.exerciseId`, `ProgressionScheme.exerciseId` |
| `Folder` | Organizational group for routines | Parent of `Routine.folderId`; user-created, user-named |
| `Routine` | Ordered blueprint for a workout | `folderId → Folder` (NULL = unfiled); owns `PlannedSet` rows by `routineId`; schemes via `ProgressionScheme.routineId` |
| `PlannedSet` | One intended set inside a routine | `routineId → Routine`, `exerciseId → Exercise`; dual-column target read by the session as the plan |
| `WorkoutSession` | One completed or in-progress training block | Parent of `CompletedSet.sessionId`; carries import metadata (#15) |
| `CompletedSet` | One actually-performed set | `sessionId → WorkoutSession`, `exerciseId → Exercise`; dual planned/actual per #2's 1-tap-accept; feeds PRs and analytics |
| `PersonalRecord` | One best-effort record for an exercise | `exerciseId → Exercise`, `setId → CompletedSet` (the set that earned it, NULL for seeded/manual) |
| `BodyMetric` | One body measurement (weight, body-fat, etc.) | Free-standing; `recordedAt` is the timeline key |
| `ProgressionScheme` | Per-routine-per-exercise progression + warmup config (#5/#16) | `routineId → Routine`, `exerciseId → Exercise`, `lastDeloadSessionId → WorkoutSession` (NULL if never deloaded) |

**(b) Field contracts**

`?` = optional (SQL NULL). Timestamps are ISO-8601 UTC text. All `id` are UUID strings (36-char v4, lowercase-hyphenated).

```
Folder = { id, name, createdAt, updatedAt, deletedAt? }

Exercise = { id, name, exerciseType: strength|cardio|custom, equipmentSlug?,
             primaryMuscleId?, secondaryMuscleIdsJson?, instructions?,
             isCustom: 0|1, createdAt, updatedAt, deletedAt? }

Routine = { id, folderId?, name, sortOrder: int, createdAt, updatedAt, deletedAt? }

PlannedSet = { id, routineId, exerciseId, sortOrder: int,
               plannedWeight?, plannedReps?, plannedDuration?,
               setClass: warmup|work,           -- 0002 add; NULL pre-0002
               createdAt, updatedAt, deletedAt? }

WorkoutSession = { id, name?, notes?,                     -- 0003 adds name/notes
                   startedAt, endedAt?,
                   importSource?, importKey?,             -- 0003 Hevy columns
                   createdAt, updatedAt, deletedAt? }

CompletedSet = { id, sessionId, exerciseId, sortOrder: int,
                 plannedWeight?, plannedReps?, plannedDuration?,
                 actualWeight?, actualReps?, actualDuration?,
                 status: planned|completed|failed|dropped,
                 setClass: warmup|work,           -- 0002 add; NULL pre-0002
                 completedAt?,
                 createdAt, updatedAt, deletedAt? }

PersonalRecord = { id, exerciseId, setId?, kind: weight|volume|rep,
                   value: real, achievedAt,
                   createdAt, updatedAt, deletedAt? }

BodyMetric = { id, kind: bodyWeight|bodyFat|weight,
               value: real, unit: kg|lb|pct,
               recordedAt,
               createdAt, updatedAt, deletedAt? }

ProgressionScheme = { id, routineId, exerciseId,
                      scheme: linear|double|percentage,  -- #5
                      incrementValue?, doubleProgressionMinReps?, doubleProgressionMaxReps?,
                      warmupEnabled: 0|1,                -- #16
                      stallCount: int, stallMuted: 0|1,
                      lastDeloadSessionId?,
                      createdAt, updatedAt, deletedAt? }
```

Weight and reps fields use REAL/INTEGER respectively; `plannedDuration`/`actualDuration` are INTEGER seconds. `secondaryMuscleIdsJson` is a TEXT JSON array of muscle slugs, NULL when unset.

**(c) Invariants + derivation**

1. **INV-1 (UUID identity):** every row's `id` is a UUID generated client-side at insert. No integer PKs, no server-assigned IDs, no ID-mapping layer — ever (Source: #4).
2. **INV-2 (timestamps):** `createdAt` is set at insert and never mutated. `updatedAt` is bumped on every UPDATE; it is the LWW watermark for sync (Source: #4).
3. **INV-3 (tombstone deletes):** no row is ever hard-deleted. Delete = `deletedAt = now`. Readers filter `deletedAt IS NULL` by default (Source: #4).
4. **INV-4 (additive-only):** migrations only ADD tables or ADD nullable columns with NULL or constant defaults. Existing columns are never renamed, retyped, or dropped (Source: #4).
5. **INV-5 (dual planned/actual):** `CompletedSet` stores the immutable plan (`plannedX`, from the routine at session start) and the live actuals (`actualX`). `plannedX` may be NULL for imported or ad-hoc sets where no plan existed; `actualX` may be NULL for sets not yet performed (Source: #2, #15).
6. **INV-6 (warmup class additivity):** `setClass` was added in migration 0002 as `'work'` default NULLable. Rows inserted before 0002 have NULL; readers coalesce NULL → `'work'`. Warmup rows are excluded from stall detection, clean-session checks, and PR computation; included in volume (Source: #16).
7. **INV-7 (import identity):** `WorkoutSession.importKey` is the dedupe key from the source system (Hevy UUID or filename-hash). UNIQUE at the DB layer so a re-import is a no-op, never a duplicate (Source: #15).

No derived fields are stored; all analytics recompute from `CompletedSet` at read time.

## 4. Business Rules

- **BR-001 (additive-only migration):** a migration may add a table, add a nullable column, add a column with a constant DEFAULT, or add an index. It must never rename, retype, or drop a column or table. Migration numbers are monotonic integers 0001…0003 for this contract; later contracts extend. (Source: #4)
- **BR-002 (migration idempotency):** applying 0001→0003 to a fresh database, then re-running the migration list, must be a no-op — GRDB's migrator tracks applied identifiers in `grdb_migrations`; the same identifier twice is an error in GRDB, which we treat as already-applied. The Node verifier proves freshness: apply 0001–0003 once, row counts and PRAGMA user_version stable. (Source: #19)
- **BR-003 (tombstone semantics):** DELETE statements are banned at the DAO layer. A delete writes `deletedAt = <ISO-8601-UTC-now>` and bumps `updatedAt`. Rows with `deletedAt NOT NULL` are excluded from default fetches; sync sends tombstones so peers mirror the delete. (Source: #4)
- **BR-004 (dual-column lawful NULL):** on `CompletedSet`, `plannedWeight`/`plannedReps`/`plannedDuration` are NULL when the set was ad-hoc (no routine) or imported; `actualWeight`/`actualReps`/`actualDuration` are NULL when the set is still in `planned` status. A `completed` set must have non-NULL actuals for its `exerciseType`; this is enforced by callers, not a CHECK constraint (callers differ per #15 import vs ✓ 1-tap). (Source: #2, #15)
- **BR-005 (timeline ordering):** `CompletedSet.sortOrder` is per-`sessionId`, zero-based, contiguous; a reader reconstructing a session orders by `sortOrder ASC, completedAt ASC`. `BodyMetric.recordedAt` and `PersonalRecord.achievedAt` are the timeline sort keys for their entity lists; `createdAt`/`updatedAt` are write metadata, never display order. (Source: #3, #9)
- **BR-006 (warmup exclusion):** progression-engine inputs filter `setClass != 'warmup' OR setClass IS NULL` (pre-0002 rows count as work); volume aggregates include warmup rows (`SUM(actualWeight * actualReps)` over all non-deleted, non-NULL actuals); PR computation excludes warmup rows regardless of actuals present. (Source: #16)
- **BR-007 (import dedupe):** an import with `importKey` already present in `workout_session` (non-tombstoned) is skipped, not errored. The import writes `importSource = 'hevy'` (future: other slugs) and `importKey = <stable source key>`. Hand-entered sessions have both NULL. (Source: #15)
- **BR-008 (stall tracking shape):** `ProgressionScheme.stallCount` is the consecutive-sessions-since-progress counter the engine (#5) increments; `stallMuted = 1` suppresses banner display without resetting the count. `lastDeloadSessionId` references the session in which a deload was last applied, NULL if never. The scheme table stores no computed suggestions — those derive at read time. (Source: #5, #16)

## 5. API Contract

Local-only; streams nothing at v1. This section is the *pre-computed* sync seam per #4 so the cloud bolt-on is schema-compatible.

- **Streams:** all nine entities stream except `BodyMetric` (stays local; user exports manually per #28). Every streamed field is marked `NOT NULL`-able-with-meaning or nullable per §3(b); no field is ever renamed or removed per BR-001.
- **Sync semantics:** field-level last-write-wins keyed on `updatedAt` (INV-2). Deletes are tombstones (`deletedAt` set), never row removal — a receiving peer applies the tombstone by `id`. Identity is `id` (UUID) at every table; no mapping table, no server-ID shadow columns, now or later.
- **Endpoint contracts:** none at v1. When sync ships (#28+), endpoints are append-only PATCH-per-field keyed on `updatedAt`; the server moves, never invents, values.
- **Precision per #4:** conflict granularity is FIELD (not row); the key is `updatedAt` (not a vector clock); deletions are tombstones.

## 6. UI Copy

Settings surface and fatal-recovery path only. All other DB errors surface as generic fallback messages — wiring them is contract `SC-settings`'s job, not this one's.

| Key | String |
|---|---|
| `foundation.db.fatalTitle` | "Storage unavailable" |
| `foundation.db.fatalBody` | "Moore's local database can't be opened. Your training data may be at risk. Export a backup from Settings if you can, then reinstall the app." |
| `foundation.db.fatalAction` | "Export backup" |
| `foundation.db.migrationFailedTitle` | "Update failed" |
| `foundation.db.migrationFailedBody` | "This update requires a database change that didn't complete. Don't delete the app — export your data and contact support." |
| `foundation.db.migrationFailedAction` | "Contact support" |
| `foundation.db.corrupted` | "The database file is damaged. Restore from your last backup." |
| `foundation.db.unknownError` | "Something went wrong with local storage. Try again." |

No other DB errors have user-facing strings in this contract; lower-severity failures are logged and retried silently.

## 7. Acceptance Criteria

Test fixtures under `Tests/MooreFoundationTests/Fixtures/round-trip-vector-NN.json` line up with these vectors; the Node verifier runs them against an in-memory SQLite with 0001→0003 applied.

| # | Axiom | Expected |
|---|---|---|
| V1 | Apply 0001 → 0002 → 0003 to a fresh in-memory DB | All three succeed; `PRAGMA user_version` reflects 3 applied migrations; every table exists |
| V2 | Re-run the migration list | No-op (GRDB migrator skips applied identifiers); schema unchanged |
| V3 | Round-trip `Folder` (insert → read) | Identical values for every field, including NULL `deletedAt` |
| V4 | Round-trip `Exercise` (custom + non-custom, NULL muscle) | Identical values; NULL `primaryMuscleId` reads back NULL, not "" |
| V5 | Round-trip `Routine` (folder NULL and folder-linked) | Identical values |
| V6 | Round-trip `PlannedSet` with `setClass='work'`, NULL weight, planned reps set | Identical values; `setClass` preserved |
| V7 | Round-trip `WorkoutSession` hand-entered (NULL import fields) | `importSource`, `importKey`, `name`, `notes` all NULL on read |
| V8 | Round-trip `WorkoutSession` imported (`importSource='hevy'`, populated `importKey`) | Identical values; UNIQUE constraint on `importKey` rejects a second insert of the same key with an integrity error |
| V9 | Round-trip `CompletedSet` dual-column (planned + actual both set, status completed) | Identical values; `plannedWeight ≠ actualWeight` preserved distinctly |
| V10 | Round-trip `CompletedSet` imported shape (planned NULL, actual set, status completed) | `plannedWeight`/`plannedReps`/`plannedDuration` read back NULL; actuals intact |
| V11 | Round-trip `PersonalRecord` with NULL `setId` (manual/kind=rep) | Identical values |
| V12 | Round-trip `BodyMetric` (`kind='bodyWeight'`, `unit='kg'`) | Identical values |
| V13 | Round-trip `ProgressionScheme` with all `#5` fields incl. `warmupEnabled=0, stallCount=2, stallMuted=0, lastDeloadSessionId` set | Identical values |
| V14 | Tombstone: insert `Exercise`, set `deletedAt`, fetch with default `deletedAt IS NULL` filter | Row invisible to default fetch; row present in raw scan including-tombstones |
| V15 | Dual-column preservation stress: two `CompletedSet` rows same session, one planned-only (status planned), one actual-only-copied (planned NULL) | Both round-trip with their NULLs distinct — no cross-contamination of columns |

Property tests: for any randomly generated entity instance, insert → SELECT by id = the instance (INV-1, INV-4). Cited as INV-1/INV-4 in test names.

## 8. Rejected Alternatives

- **Auto-increment integer PKs** → rejected: #4 mandates UUID identity so sync needs no ID-mapping layer; integers would collide across devices.
- **A single JSON blob column per entity** → rejected: kills field-level LWW (#4) and forces whole-row merges on any conflict.
- **Hard deletes with a separate `deleted_log` table** → rejected: splits the read path (two queries per fetch) and breaks #4's "tombstone on the row itself" rule (INV-3).
- **Replacing `setClass` with a separate `WarmupSet` table** (per #16's open question) → rejected: duplicates every CompletedSet query path for a one-bit distinction; a nullable TEXT column with a default of `'work'` is additive per BR-001 and keeps the flat list per #3.
- **Storing progression suggestions** (cache of "suggest 82.5 next") → rejected: suggestions derive at read from `CompletedSet` + `ProgressionScheme`; stored derivation can go stale, derivation rules evolve.
- **Notion of a `Template` separate from `Routine`** → rejected: #3 already collapses these; a `Routine` *is* the template. Adding a second entity would double the CRUD surface for no user-visible distinction.

## 9. Downstream Effects

- Every other contract — `SC-exercises`, `SC-routines`, `SC-workout-logging`, `SC-rest`, `SC-progression`, `SC-warmup`, `SC-prs`, `SC-analytics`, `SC-settings`, `SC-cues`, `SC-import` — consumes this schema and cites these BR IDs.
- **Unblocks #20** (exercise library) — reads/writes `Exercise`.
- **Unblocks #21** (routines/folders) — reads/writes `Routine`, `Folder`, `PlannedSet`.
- **Unblocks #22** (active workout FSM) — writes `WorkoutSession`, `CompletedSet`.
- **Unblocks #24** (progression engine) — reads `CompletedSet`, `ProgressionScheme`.
- **Unblocks #25** (warm-up ramps) — writes `setClass='warmup'` rows.
- **Unblocks #26** (PRs) — reads `CompletedSet`, writes `PersonalRecord`.
- **Unblocks #30** (Hevy import) — writes `importSource`/`importKey`.
- **Feeds #31** (Android port) — migrations become shared `.sql` artifacts per #8.
