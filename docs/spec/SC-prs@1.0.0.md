# Contract: Personal Records + Celebrations

```yaml
---
contractId: "SC-prs"
version: "1.0.0"
status: frozen
date: "2026-08-12"
source: "#26"
supersedes: null
supersededBy: null
---
```

Personal Records are the record-book layer of Moore. This contract owns: (1) the four PR types and their math directly out of #3/SC-foundation; (2) the **two-path write model** — a live completion path that only ever *beats* an existing baseline row, and a maintenance path (import / edit / delete re-derivation) that seeds baselines and keeps them truthful; (3) the in-session precedence and one-cue-per-set budget; (4) Summary escalation morphology (`cue.pr.summary`).

Consumes `SC-foundation@1.0.0` (schema + invariants, migrations 0001–0003), `SC-workout-logging@1.0.0` (CompletedSet lifecycle), `SC-warmup@1.0.0` (`setClass` gates), `SC-exercises@1.0.0` (exercise metric). Adds **one additive migration**, `0008_personal_records.sql` (§3d), which heals 0001's legacy `personal_record` shape (`kind CHECK IN ('weight','volume','rep')`, no `sessionId`) into the canonical #3 shape — rows are never destroyed. Cue IDs and haptic taxonomy adopt #10's resolution verbatim; this contract adds no new cue IDs.

## 2. State Machine

**None** for this contract. `personal_record` writes are transactional row updates/inserts/tombstones driven by CompletedSet lifecycle events; the table itself carries no FSM state. Trigger surface:

- `planned → completed` on a set → `PersonalRecordDAO.writeFromSet` → `PREngine.processNewSet` → beaten kinds' rows update, `PRWrite.fired` returned for caller to dispatch `cue.pr.achieved`.
- Import / edit / tombstone of a `status='completed'` set → `PersonalRecordDAO.rederive(exerciseId)` → `PREngine.rederive` → baselines seeded / re-pointed / tombstoned. Never returns a cue.
- Session Summary render → read-only query per session (INV-PR5); `cue.pr.summary` is a render-time visual.

## 3. Data Schema

### (a) Entity table (post-0008 canonical)

```
PersonalRecord = {
  id TEXT PK,
  exerciseId TEXT NOT NULL REFERENCES exercise(id),
  sessionId  TEXT NOT NULL REFERENCES workout_session(id),  -- 0008 add; the session where achieved
  setId      TEXT REFERENCES completed_set(id),              -- nullable; the set that holds the record
  kind       TEXT NOT NULL CHECK (kind IN ('max_1rm','max_volume','max_reps','max_duration')),
  value      REAL NOT NULL,                                  -- unit per kind per §3b
  achievedAt TEXT NOT NULL,                                  -- ISO-8601 UTC; holding set's completedAt
  createdAt  TEXT NOT NULL,
  updatedAt  TEXT NOT NULL,
  deletedAt  TEXT                                            -- tombstone per SC-foundation INV-3
}
```

Indexes (created by 0008):
- `personal_record_exercise_idx ON personal_record(exerciseId) WHERE deletedAt IS NULL`
- `personal_record_session_idx  ON personal_record(sessionId)  WHERE deletedAt IS NULL` — Summary + History badge probe.
- `personal_record_kind_ex_idx  ON personal_record(exerciseId, kind) WHERE deletedAt IS NULL` — per-kind baseline probe at write time.

### (b) Value semantics per kind

| kind | value carries | computed from |
|---|---|---|
| `max_1rm` | estimated one-rep max (Epley, set's weight unit) | `actualWeight × (1 + actualReps/30)`; requires `actualWeight > 0 AND actualReps > 0` |
| `max_volume` | single-set volume | `actualWeight × actualReps`; same gate |
| `max_reps` | rep count in one set | `actualReps`; any weight including NULL (bodyweight) |
| `max_duration` | duration in seconds | `actualDuration`; **exercise metric = `duration` only** |

### (c) Invariants (additive to SC-foundation §3c)

- **INV-PR1 (closed kind vocabulary).** Writers only ever persist the four canonical strings; old readers ignore unknown kinds.
- **INV-PR2 (one live row per (exerciseId, kind)).** The table holds the *current best* per kind — a bookmark, not a timeline. Exceeds update in place; re-derivation may lower, re-point, seed, or tombstone. The event timeline is derivable from `CompletedSet` (SC-foundation invariant 5: analytics never persists).
- **INV-PR3 (two write paths, both transactional; only the live path cues).** Row creation lives in `rederive` (import/edit/delete). Live set completion only updates existing rows and only then fires a cue. This split is the whole of the first-touch story (BR-002).
- **INV-PR4 (re-derivation recomputes from CompletedSet).** `rederive` reads every live `status='completed' AND coalesce(setClass,'work')='work'` set for the exercise, across all sessions. It never reads `personal_record` for input — CompletedSet is the source of truth.
- **INV-PR5 (Summary reads, never writes).** Summary's PR section derives from `personal_record WHERE sessionId = ?` at render time.

### (d) Migration `0008_personal_records.sql` — heals 0001's legacy shape

0001 shipped `kind CHECK IN ('weight','volume','rep')` and **no `sessionId` column**, diverging from #3's Data Schema. SQLite cannot ALTER a CHECK constraint, so 0008 uses the same table-rebuild pattern as `0007_progression_full.sql`, additive in behavior (no row ever lost):

1. `CREATE TABLE IF NOT EXISTS personal_record_v2` with the §3a shape (widened CHECK, `sessionId TEXT NOT NULL`).
2. Copy legacy rows: `weight → max_1rm`, `volume → max_volume`, `rep → max_reps`; backfill `sessionId` via the `setId → completed_set.sessionId` join; unresolved rows carry the `''` sentinel (legacy-only; readers tolerate, writers never produce).
3. `ALTER TABLE personal_record RENAME TO personal_record__legacy_0001`; `ALTER TABLE personal_record_v2 RENAME TO personal_record`.
4. Rebuild the three §3a indexes.

## 4. Business Rules

- **BR-001 (candidates: completed work sets only).** A set is eligible iff `status='completed'` AND `coalesce(setClass,'work')='work'`. **Failed sets never write PRs** (#3: actuals recorded ≠ PR). **Dropped sets never write PRs**. **Warmup rows never write PRs and never feed bookmarks** (#16 §5: a bar×10 must never hold `max_reps`).
- **BR-002 (two paths; first-touch lives in the live path).** Live completion (`processNewSet`) writes and cues **only** when a baseline row already exists for `(exerciseId, kind)` and the new value strictly exceeds it (BR-003). With no baseline row the function returns nil — no row, no toast, no haptic. A user's first-ever session on an exercise therefore fires **zero** cues and writes **zero** rows (#10 tier 1). Baseline rows come exclusively from the maintenance path (BR-009), which every import/edit/delete triggers — so a first session's sets become the seeded baseline the *moment* the first edit/re-derivation lands, and from then on live completion beats-and-cues normally.
- **BR-003 (strict exceed; ties are not PRs).** Writes only on `value > baseline.value`. Equality writes nothing, fires nothing. Floats compare with `>`, no epsilon; stored values unrounded.
- **BR-004 (per-kind gating by metric).** `max_1rm`/`max_volume` require `actualWeight > 0 AND actualReps > 0` (bodyweight never holds either). `max_reps` requires `actualReps > 0`. `max_duration` requires the exercise metric `= duration` AND `actualDuration > 0` — duration exercises hold max_duration only; reps-metric exercises never hold it.
- **BR-005 (one cue per set; precedence `max_1rm > max_volume > max_reps > max_duration`).** One set beating multiple kinds updates every beaten kind's row in one transaction (INV-PR2) but returns exactly **one** cue descriptor — headline = highest precedence. Toast names the headline kind only; other kinds surface silently on Summary (#10 tier 2). The PR's `celebration` haptic subsumes `cue.set.completed`'s tick (per-set budget: one haptic).
- **BR-006 (transactional live write).** `writeFromSet` inside one transaction: load candidate set + baseline rows → `processNewSet` → update-in-place each beaten kind (INV-PR2) → commit → return `PRWrite { fired: PRFiredCue? }`. Baseline rows are never created on this path.
- **BR-007 (edit re-derives).** Editing actuals on a `completed` set triggers `rederive(exerciseId)`. Only rows whose (value, holder) actually moved are rewritten — no `updatedAt` churn otherwise.
- **BR-008 (delete re-derives).** Tombstoning a `completed` set triggers `rederive(exerciseId)`. A deleted holder's row re-points at the next-best qualifying set (`achievedAt` follows); kinds with no qualifying set are tombstoned.
- **BR-009 (re-derivation seeds baselines, never cues).** Holder per kind = max value across qualifying sets (ties → earliest `completedAt`). Missing rows for qualifying kinds are **inserted** (this is the only row-creation path); moved rows update; dead rows tombstone. Returns rows, never a `PRFiredCue` (#10 tier 1: no retroactive promotion of cues).
- **BR-010 (Summary escalation).** 0 rows in session → no PR section. 1 row → single `summary.pr.card`. ≥2 rows → banner `summary.pr.banner` ("🏆 {n} new PRs") above cards ordered by BR-005 precedence. `cue.pr.summary`: no haptic, no audio.
- **BR-011 (in-session never escalates).** In-session celebration is always a flat single toast regardless of PR count (#10 tier 3); Summary owns all escalation.
- **BR-012 (keyed copy).** All strings keyed per #6, voice per #17 (declarative, factual — "New PR +2.5 kg", never "Wow!").

## 5. API Contract

`MooreRecords` module; depends on `MooreFoundation` (row types) + GRDB. Engine is seam-1 (pure, closed-form); DAO is seam-2 (GRDB).

```swift
public enum PRKind: String, Codable, CaseIterable, Sendable {
    case max1rm = "max_1rm", maxVolume = "max_volume", maxReps = "max_reps", maxDuration = "max_duration"
    public var precedenceRank: Int { get }   // 0..3 in BR-005 order
}

public enum SeamMetric: String, Codable, Sendable { case reps, duration }

public struct PersonalRecord: Codable, Equatable, Sendable { /* §3a fields */ }

public struct ReferenceSessionSet: Equatable, Sendable {
    public var id, sessionId, exerciseId: String
    public var status: SetStatus
    public var setClass: SetClass?               // nil ⇔ .work (INV-6)
    public var actualWeight: Double?
    public var actualReps: Int?
    public var actualDuration: Int?
    public var completedAt: String?
    public var exerciseDefaultMetric: SeamMetric?
}

public struct PRFiredCue: Equatable, Sendable {  // cue.pr.achieved descriptor
    public var cueId: String        // "cue.pr.achieved"
    public var hapticClass: String  // "celebration"
    public var headlineKind: PRKind
    public var value: Double
    public var exerciseId: String
}

public struct PRWrite: Equatable, Sendable {     // live path result
    public var written: [PRKind]    // == beaten (BR-002: live path only ever beats)
    public var beaten: [PRKind]
    public var values: [PRKind: Double]
    public var fired: PRFiredCue?   // nil ⇔ nothing beaten
}

public enum PREngine {
    /// LIVE path (BR-002/BR-003/BR-005). Baseline row absent ⇒ nil (no seed,
    /// no cue). Strict exceed ⇒ write + single headline cue.
    public static func processNewSet(
        set: ReferenceSessionSet,
        baselines: [PRKind: PersonalRecord]
    ) -> PRWrite?

    /// MAINTENANCE path (BR-007/BR-008/BR-009). Per-kind bookmark over full
    /// live history; seeds missing rows, re-points moved holders; silent.
    public static func rederive(exerciseHistory: [ReferenceSessionSet])
        -> [PRKind: (value: Double, setId: String?, sessionId: String?, achievedAt: String?)]
}

public struct PersonalRecordDAO: Sendable {
    public init(dbQueue: DatabaseQueue)
    @discardableResult
    public func writeFromSet(_ setId: String) throws -> PRWrite?   // BR-006
    public func rederive(exerciseId: String) throws                // BR-007/BR-008/BR-009
    public func fetchBest(exerciseId: String) throws -> [PRKind: PersonalRecord]
    public func fetchSessionPRs(sessionId: String) throws -> [PersonalRecord]  // BR-010, precedence-ordered
}
```

## 6. UI Copy

Keyed per #6; voice per #17 — declarative, no exclamation marks.

| Key | String |
|---|---|
| `toast.pr.new` | "🏆 New {kindLabel} PR — {exerciseName} {value}" |
| `pr.kind.max_1rm` | "1RM" |
| `pr.kind.max_volume` | "Volume" |
| `pr.kind.max_reps` | "Reps" |
| `pr.kind.max_duration` | "Duration" |
| `summary.pr.card` | "{exerciseName} {kindLabel} {value}" |
| `summary.pr.banner` | "🏆 {n} new PRs" |
| `history.badge.pr` | "PR" |

## 7. Acceptance Criteria

Fixtures under `Tests/MooreRecordsTests/Fixtures/*.json`; `VerifyRecords.mjs` runs them against in-memory SQLite with 0001–0008 applied, fresh DB per fixture.

| # | Setup | Action | Expected | Cites |
|---|---|---|---|---|
| V1 | Bench: baseline row max_1rm=128.33 (110×5 in prior session). | Complete 115×5 (Epley 134.17). | max_1rm row updates to 134.17; `fired.headlineKind=max_1rm`. max_volume has no row → not written (BR-002). | BR-002, BR-003, BR-006 |
| V2 | Curl: baseline rows exist for max_1rm (52.13), max_volume (184), max_reps (4). | Complete 50×5 (1RM 58.33, volume 250, reps 5 — beats all three). | All three rows update; exactly one cue, headline `max_1rm`. | BR-005, BR-006 |
| V3 | Brand-new exercise, first-ever session; no baseline rows. | Complete 40×10 then 50×9. | Both complete: no rows, no cues (`writeFromSet` returns nil both times). Then an edit/delete/import runs `rederive` → baseline rows seed (max_1rm 65, max_volume 450, max_reps 10 all @ set-f2) silently. | BR-002, BR-009 |
| V4 | History 100×8 completed + failed set 100×12 (beats reps). | Complete the failed set's write attempt; then a clean 100×10 with only max_1rm baseline present (126.67). | Failed: nothing. Clean: max_1rm → 133.33 fired; other kinds absent (no rows). Failed set's 12 reps invisible forever. | BR-001, BR-002 |
| V5 | Plank (duration metric): baseline max_duration=60. | Complete 75s. | max_duration row → 75, fired `max_duration`; no other kind exists. | BR-004 |
| V6 | Rows: 1RM=116.67@setC, volume=540@setB over sets A=80×5, B=90×6, C=100×5. | (a) Edit B upward to 105×5; (b) edit holder C down to 70×5 (row ex-row variant). | (a) 1RM row → setB @ 122.5; volume → 525@B; reps row seeds to 6@B. (b) Row drops to next-best (96@r1). | BR-007, BR-009 |
| V7 | Same rows. | Tombstone set C. | max_1rm → set B @ 108 with B's achievedAt. | BR-008 |
| V8 | OHP: baseline row 57@set-o2; sets o1=40×10, o2=45×8 only. | Tombstone set-o2. | Bookmark re-seeds to o1: 1RM 53.33, reps 10, volume 400 — all @ o1; row survives (INV-PR2 while any qualifying set exists). | BR-008, BR-009 |
| V9 | Squat: baseline max_1rm=81.67@70×5; warmup 20×15 exists. | Write attempt on warmup; then complete work set 75×5. | Warmup: nothing. Work: max_1rm → 87.5 fired; warmup 15 never touches max_reps. | BR-001, BR-004 |
| V10 | — | — | Covered by V3: first session = zero cues at every step. | BR-002, BR-011 |
| V11 | Session with 1 PR row. | Summary render. | Single card, no banner. | BR-010 |
| V12 | Session with 3 PR rows across kinds/exercises. | Summary render. | Banner n=3 above cards in precedence order max_1rm → max_volume → max_duration. | BR-010, BR-005 |
| V13 | Pull-up: baseline max_reps=12 (bodyweight). | Complete bodyweight 15. | max_reps → 15, fired `max_reps`; max_1rm/max_volume never written (weight gate). | BR-004 |

Edge cases held: equal-to-best writes/fires nothing (BR-003, V13-adjacent); `actualWeight=0` gates out 1RM/volume; two warmups + zero work = zero rows; re-derivation with empty history tombstones all the exercise's rows.

## 8. Rejected Alternatives

- **Live-path seeding (row written on first completion, cue suppressed)** → rejected at ticket ruling: row creation belongs in re-derivation only; the live path having one job (beat or nothing) keeps BR-002 a single boolean with no session-boundary detection.
- **Derived/on-the-fly PRs (no table)** → rejected per #3: persisted rows give fast toasts + History badges.
- **Timeline PR table (append-only event log)** → rejected: duplicates CompletedSet authority (INV-PR2).
- **Multiple toasts per multi-kind set** → rejected per #10: one celebration per set; Summary enumerates.
- **Mid-workout escalation banner** → rejected per #10 tier 3 (BR-011).
- **Retroactive cue promotion on re-derivation** → rejected per #10 tier 1 (BR-009 is silent).
- **Audio on `cue.pr.achieved`** → rejected per #10 taxonomy (haptic + visual only).

## 9. Downstream Effects

- **Feeds #27 (Activity feed / badges):** reads `personal_record.sessionId` + `personal_record_session_idx`; Summary binds §6 keys.
- **Feeds #28 (Settings):** any future "reset records for exercise" destructive writes through this DAO (tombstone only).
- **Feeds #29 (haptic driver):** consumes `PRFiredCue.hapticClass = "celebration"`.
- **Feeds #8 (Android port):** frozen v1.0.0; `PREngine` closed-form pure, byte-identical across platforms; §6 keys survive verbatim.
