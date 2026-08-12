# Contract: Hevy CSV Import

```yaml
---
contractId: "SC-import"
version: "1.0.0"
status: frozen
date: "2026-08-12"
source: "#30"
supersedes: null
supersededBy: null
---
```

The one-time migration channel for Hevy refugees: parse a Hevy export CSV, preview it dry, then land it atomically into the #3 schema. Consumes `SC-foundation@1.0.0` (nine entities; migration 0003 already shipped the `workout_session.name/notes/importSource/importKey` columns + UNIQUE partial index), `SC-exercises@1.0.0` (name normalization BR-001, built-in library), `SC-prs@1.0.0` (maintenance-path re-derivation, BR-009). The format spec is the #15 research resolution verbatim: single flat CSV, UTF-8, RFC 4180, snake_case headers, one row per logged set; session/exercise structure recovered by grouping on `(start_time, title)`. Every exported row is a logged set, so every row becomes a `status='completed'` CompletedSet with actuals filled and `plannedX` NULL (lawful: SC-foundation INV-5). Import is a migration, not a sync: later edits inside Hevy never propagate.

## 2. State Machine

The import flow is a five-state machine owned by the Settings → Data & sync surface (#7). No DB write exists before `[Import]` is confirmed.

| State | Meaning | Entered by | Exits |
|---|---|---|---|
| `idle` | No import in flight; the "Import from Hevy (CSV)" row is tappable | Landing on Data & sync, or any terminal below | file-picked → `parsing` |
| `parsing` | File read + full in-memory plan build (BR-014); zero DB contact | System file picker returns a file | plan built → `preview`; parse/abort error → `error` |
| `preview` | Dry-run counts on screen; unit override + per-exercise override controls; quarantined rows inspectable | Plan built without abort | `[Import]` → `applying`; `[Cancel]` → `idle` (plan discarded) |
| `applying` | One SQLite transaction runs (BR-015) | `[Import]` tapped | commit → `done`; any failure → `error` (full rollback) |
| `done` | Summary line rendered (§6) | Transaction committed | dismissal → `idle` |
| `error` | Fatal parse state (`notHevyExport`) or apply failure; message rendered, nothing persisted | Abort per BR-012, or rolled-back transaction | dismissal → `idle` |

**Invariants**

- **INV-IM1 (no write before confirm):** nothing touches the database in `parsing` or `preview`. Cancel at any point before `[Import]` discards the plan wholesale.
- **INV-IM2 (all-or-nothing):** `applying` is exactly one transaction; any error rolls back everything — no partial-import state exists (SC-foundation BR-003 tombstones are the only delete mechanism; import itself never deletes).
- **INV-IM3 (quarantine precedes apply):** quarantined rows are excluded during plan build; the applied set is all-valid by construction — there is no mid-apply row skip.
- **INV-IM4 (idempotent re-import):** applying the same file twice never duplicates: `importKey` UNIQUE partial index (migration 0003) + INSERT-OR-IGNORE make the second run a counted no-op (BR-013).
- **INV-IM5 (preview truth):** every count rendered in `preview` is computed from the same `ImportPlan` that `applying` consumes; the preview never re-parses.

## 3. Data Schema

### (a) Entity table

No new entities. Import writes exactly the sync-ready shapes #4 froze, into existing tables:

| Entity | Import's role | Key relationships |
|---|---|---|
| `Exercise` | Matched (built-in or existing custom) or created (`isCustom=1`) | `CompletedSet.exerciseId → Exercise` |
| `WorkoutSession` | One per `(start_time, title)` group; carries `importSource='hevy'`, `importKey`, `name`, `notes` | `CompletedSet.sessionId → WorkoutSession` |
| `CompletedSet` | One per CSV data row that survives plan build | `sessionId → WorkoutSession`, `exerciseId → Exercise` |
| `PersonalRecord` | Re-derived (maintenance path only) for every affected exercise | `exerciseId → Exercise`, `sessionId → WorkoutSession` |

`routineId` is NULL on every imported session (a session may have zero planned sets — SC-foundation INV-5; the #5 progression engine never sees routineId-NULL sessions).

### (b) Derived (never persisted) types

```
HevyUnit        = kg | lb
ImportOptions   = { targetUnit: HevyUnit,                     -- default kg; app display unit
                    timezoneOffsetMinutes: int,               -- device-local at import moment (BR-017)
                    now: ISO-8601-UTC,                        -- write metadata stamp
                    unitOverrides: [normalizedName → HevyUnit], -- per-exercise (BR-010)
                    existingImportKeys: set<string> }         -- DB probe before plan (BR-013)
LibraryRow      = { id, name, nameNormalized, equipmentSlug?, isCustom: 0|1 }
ParsedRow       = { rowNumber: int, title, description, startTimeRaw, endTimeRaw,
                    exerciseTitle, supersetIdRaw, exerciseNotesRaw, setIndexRaw,
                    setType, weightKgRaw, weightLbsRaw, repsRaw,
                    distanceKmRaw, distanceMilesRaw, durationRaw, rpeRaw }
ImportSetPlan   = { exerciseRef: existingId | newExerciseKey(normalizedName),
                    sortOrder: int,                            -- 0-based file order in session
                    actualWeight?, actualReps?, actualDuration?, completedAt }
ImportSessionPlan = { importKey, name, notes?, startedAt, endedAt?, sets: [ImportSetPlan],
                      alreadyImported: 0|1 }
NewExercisePlan = { name,                    -- displayForm, case preserved
                    normalizedName, metric: reps|duration }
QuarantinedRow  = { rowNumber: int, column, value, message }
ImportPlan      = { unit: HevyUnit?, now: ISO-8601-UTC,
                    sessions: [ImportSessionPlan], newExercises: [NewExercisePlan],
                    quarantined: [QuarantinedRow], counts: PreviewCounts, warnings: [string] }
PreviewCounts   = { dataRows, emptyRowsSkipped, duplicatesCollapsed, sessionsFound,
                    setsImported, exercisesMatched, sessionsAlreadyImported,
                    cardioRowsSkipped, foldedSetTypes, quarantinedCount,
                    metadataDropped: { rpe, exerciseNotes, supersetId } }
ImportSummary   = { sessionsImported, sessionsSkippedAlreadyImported,
                    setsImported, exercisesCreated }
```

### (c) Invariants + derivation rules

1. **INV-IM6 (imported actuals only):** every imported CompletedSet is `status='completed'`, `plannedWeight/plannedReps/plannedDuration` NULL, `setClass` NULL (≡ `'work'` per SC-foundation INV-6), `completedAt = session.endedAt ?? session.startedAt`. Analytics/adherence queries must treat NULL plannedX as "no plan", never zero (SC-foundation BR-004; #15 ruling).
2. **INV-IM7 (session identity = importKey):** two row-groups are one session iff they share `importKey` (BR-013). Grouping never assumes row contiguity in the file.
3. **INV-IM8 (custom metric representation):** a created custom Exercise stores `exerciseType='custom'` when its inferred metric is reps and `exerciseType='cardio'` when duration — the v1 representation of #3's `defaultMetric` (the SC-prs metric-resolution precedent: duration metric ⇔ `exerciseType='cardio'` until the 0004-rewrite lands the dedicated column; docs/MIGRATION-INTEGRATION-NOTE.md). `isCustom=1` in both cases.
4. **Derivation — PR re-derivation:** after the set inserts, for each affected exerciseId, recompute the per-kind bookmark over the exercise's full live history and seed/update/tombstone `personal_record` rows — SC-prs BR-009 semantics exactly (holder = max value per kind; ties → earliest `completedAt`; missing rows inserted; dead kinds tombstoned; **never cues**), inside the same transaction (BR-016).

## 4. Business Rules

- **BR-001 (container grammar):** UTF-8, comma-delimited, RFC 4180 quoting: a field beginning with `"` is quoted; `""` inside a quoted field is a literal quote; quoted fields may contain commas and CR/LF newlines; records end at CRLF or LF (lone CR tolerated); the final record may omit its newline; a leading U+FEFF BOM is stripped; an unterminated quoted field at EOF is a parse error. (Source: #15)
- **BR-002 (header normalization):** each header cell is lowercased, trimmed, and interior-whitespace-collapsed to `_` — so `start_time` and `Start Time` denote the same column. Duplicate header names: first occurrence wins, warning counted. Unknown columns are ignored (forward-compat). Recognized columns: `title, start_time, end_time, description, exercise_title, superset_id, exercise_notes, set_index, set_type, weight_kg, weight_lbs, reps, distance_km, distance_miles, duration_seconds, rpe`. Required: `start_time` and `exercise_title` — either missing aborts with `notHevyExport` before any row work. (Source: #15)
- **BR-003 (empty rows):** a data record whose every field is blank-after-trim is skipped silently (`emptyRowsSkipped` counted, never surfaced). (Source: #15)
- **BR-004 (datetime grammar):** `start_time`/`end_time` are naive local wall-times shaped `D Mon YYYY[, ]HH:MM[:SS]` — 1–2 digit day, English 3-letter month (case-insensitive), 4-digit year, optional comma, 24-hour clock, seconds optional and tolerated. Interpretation: device-local timezone at import moment (`ImportOptions.timezoneOffsetMinutes`), stored as ISO-8601 UTC text `YYYY-MM-DDTHH:MM:SSZ` (second precision, no fractional). Unparseable `start_time` → row quarantined; unparseable or blank `end_time` → session `endedAt` NULL (no quarantine). DST / foreign-timezone shift is accepted and documented: sessions logged elsewhere shift by that offset, invisible at day/week chart granularity. (Source: #15)
- **BR-005 (session grouping):** rows group by `(parsed startedAt, lower(trim(title)))` — never start_time alone, never title alone, never contiguity. Session fields: `name = trim(title)` or the `hevyImport.untitledSession` fallback when blank; `notes` = first non-blank `description` among the session's rows in file order with literal two-character `\n` sequences unescaped to real newlines, NULL when none; `endedAt` = first parseable non-blank `end_time` among the session's rows in file order, else NULL. (Source: #15)
- **BR-006 (row → CompletedSet):** every surviving row maps to one CompletedSet with `status='completed'` always — Hevy exports only logged sets, and `set_type='failure'` means taken-to-failure (a success), never our `failed`. `actualWeight` = parsed weight (blank or 0 → NULL, the bodyweight rule — never fabricate 0); `actualReps` = parsed reps (blank → NULL); duration rule: reps NULL-or-0 AND `duration_seconds > 0` ⇒ `actualDuration = duration_seconds` (weighted-duration legal: weight also stored); reps > 0 ⇒ reps set, `duration_seconds` ignored. A row with neither reps > 0 nor duration > 0: distance present ⇒ cardio row, skipped + counted (no distance field exists in #3); otherwise quarantined as `no-payload`. A session whose rows all skip produces no WorkoutSession (cardio-only sessions import nothing). `set_type ∈ {warmup, normal, failure, dropset}` all map to `completed`; non-normal values are counted as `foldedSetTypes` over the sets actually imported (the distinction is not stored); an unknown `set_type` string is tolerated as normal. `plannedX` all NULL (binding ruling, §1 preamble). (Source: #15, #3)
- **BR-007 (set ordering):** `sortOrder` is the row's 0-based file-order position within its session after skips/collapse — contiguous per SC-foundation BR-005. This preserves superset interleaving exactly as logged; `superset_id` itself is parsed, discarded, and counted under `metadataDropped.supersetId` (supersets are emergent per #2). `set_index` is validated (blank tolerated; a non-blank non-integer quarantines the row) and otherwise discarded — order is carried by file order, not by it. (Source: #15, #30)
- **BR-008 (duplicate rows):** rows sharing `(importKey, normalize(exercise_title), raw set_index)` collapse to the first occurrence; `duplicatesCollapsed` counted. (Source: #15)
- **BR-009 (exercise matching):** normalize = `lowercase(trim(collapse_whitespace))` (SC-exercises BR-001). Primary: normalized name equals a non-tombstoned library row's normalized name (built-ins seeded read-only + existing customs). Secondary: strip exactly one trailing `(Equipment)` parenthetical; match base name AND equipment, where the library row's `equipmentSlug` is NULL or equals the mapped parenthetical (map: Barbell→barbell, Dumbbell→dumbbell, Cable→cable, Machine→machine, Bodyweight→bodyweight, Smith Machine→smith, Plate→plate, Band→band, Kettlebell→kettlebell, EZ Bar→ezBar, Trap Bar→trapBar, Medicine Ball→medicineBall, Sled→sled, anything else→other); multiple candidates resolve built-ins-first, then name ASC, then id ASC. Miss → create `Exercise { id: new UUID, name: displayForm(trim(title)) — case preserved, isCustom: 1, exerciseType per INV-IM8 }`, `metric` inferred from its accepted rows (any duration-rule row ⇒ duration, else reps); a custom exercise is created only for rows accepted as sets — cardio-skipped and quarantined rows never create one; deduped within the file by normalized name, and matched against pre-existing customs by normalized name — a re-import never double-creates. Category/muscles unknown → left NULL/default. (Source: #15)
- **BR-010 (units):** declared unit = the populated weight column (`weight_kg` ⇒ kg, `weight_lbs` ⇒ lb); both present ⇒ kg wins + warning counted; neither ⇒ unit NULL. Effective unit for exercise E = `unitOverrides[normalize(E)] ?? declared`. When effective ≠ target unit, convert at write time — kg→lb × 2.20462, lb→kg ÷ 2.20462 — stored as unrounded float (display rounding stays a UI concern). Target unit defaults to kg. Conversion applies to `actualWeight` only (plannedX is NULL). (Source: #15)
- **BR-011 (discarded metadata):** `rpe` (parsed, never stored — #7 bans RPE in UI), `exercise_notes` (per-set notes, no field in #3), and `superset_id` are read and dropped, each counted under `metadataDropped`. `distance_km`/`distance_miles` are read for BR-006's cardio decision and never stored. (Source: #15, #7)
- **BR-012 (quarantine + abort threshold):** a row is quarantined — excluded from the plan and surfaced in preview with `{rowNumber (1-based data-record index after the header record), column, value, message}` — for exactly: (a) unparseable `start_time`; (b) blank `exercise_title`; (c) malformed numeric field (`weight_*`, `reps`, `duration_seconds`, `set_index`); (d) no-payload per BR-006. If quarantined rows exceed 50% of non-empty data rows, the whole import aborts with `notHevyExport` ("doesn't look like a Hevy export") — nothing written. (Source: #15)
- **BR-013 (importKey + idempotency):** `importKey = lower(trim(title)) + "|" + ISO-8601-UTC(startedAt)` second-precision. Migration 0003's UNIQUE partial index (importKey IS NOT NULL) + INSERT-OR-IGNORE on apply: a session whose key already exists (non-tombstoned) is skipped wholesale and counted as `sessionsAlreadyImported`. Preview shows "N sessions already imported (skipped)". Collision caveat accepted per #15: two genuinely different workouts sharing start minute AND title merge — vanishingly rare. (Source: #15, SC-foundation BR-007/INV-7)
- **BR-014 (dry-run preview):** the full file parses first into `ImportPlan` in memory. Preview renders §6 counts from `PreviewCounts`: sessions found, sets, matched-set count, new custom exercise names, warmup/dropset/failure folded count, cardio rows skipped, sessions already imported, detected unit + override control, per-exercise unit overrides, and the quarantined-row list. (Source: #15, #18)
- **BR-015 (atomic apply):** confirm executes ONE transaction in order: custom Exercises → WorkoutSessions (INSERT-OR-IGNORE by importKey; a session ignored by the index skips its sets and counts as skipped) → CompletedSets → PR re-derivation (BR-016). Any failure rolls back everything. Returns `ImportSummary`. (Source: #15, #18)
- **BR-016 (PR re-derivation on import):** for each exerciseId that received at least one imported set in this transaction, run the SC-prs maintenance path (BR-009 there): per-kind bookmark over full live history — `max_1rm`/`max_volume` gated `actualWeight>0 AND actualReps>0` (Epley `weight × (1 + reps/30)`), `max_reps` gated `actualReps>0`, `max_duration` gated duration-metric AND `actualDuration>0`; seeds missing rows, re-points moved holders, tombstones dead kinds; silent — never a cue. Same transaction as BR-015. (Source: #26, #15)
- **BR-017 (timezone):** export times carry no offset; they are interpreted as device-local at the import moment. Documented caveat, accepted per #15. (Source: #15)
- **BR-018 (no sync side-effects):** import never touches `syncEnabled` (#4's dormant flag), never creates routines, never writes `PlannedSet`, `BodyMetric`, `ProgressionScheme`, or `Folder`. (Source: #15, #7)

## 5. API Contract

`MooreImport` module; depends on GRDB only. Parser + engine are seam-1 (pure, closed-form, byte-identical across platforms per #8); the DAO is seam-2 (GRDB).

```swift
public enum HevyUnit: String, Codable, Sendable { case kg, lb }

public enum HevyCsvParser {
    /// RFC 4180 records (BR-001). Throws on unterminated quote.
    public static func parseRecords(_ text: String) throws -> [[String]]
    /// BR-002: lowercase + trim + interior-whitespace → "_"
    public static func normalizeHeader(_ raw: String) -> String
}

public struct ImportOptions: Equatable, Sendable {
    public var targetUnit: HevyUnit                 // default .kg
    public var timezoneOffsetMinutes: Int           // BR-004/BR-017
    public var now: String                          // ISO-8601 UTC write stamp
    public var unitOverrides: [String: HevyUnit]    // normalized exercise name → unit
    public var existingImportKeys: Set<String>      // BR-013 DB probe
}

public struct LibraryRow: Equatable, Sendable {
    public var id, name, nameNormalized: String
    public var equipmentSlug: String?
    public var isCustom: Bool
}

public enum HevyImportEngine {
    /// Full-file pure plan build (BR-002…BR-014). Throws `.notHevyExport` on
    /// missing required headers or BR-012's >50% abort. Zero DB contact.
    public static func buildPlan(
        csvText: String, library: [LibraryRow], options: ImportOptions
    ) throws -> ImportPlan
}

public struct HevyImportDAO: Sendable {
    public init(dbQueue: DatabaseQueue)
    /// BR-015/BR-016: one transaction — exercises → sessions (INSERT-OR-IGNORE)
    /// → sets → per-exercise PR re-derivation.
    @discardableResult
    public func apply(_ plan: ImportPlan) throws -> ImportSummary
}
```

Local-only otherwise; imported rows stream in phase two exactly like native rows (custom Exercises stream; built-in matches stream as ID references) — no special casing.

## 6. UI Copy

Keyed per #6; voice per #17 — declarative, factual, no exclamation marks. Surface: Settings → Data & sync → "Import from Hevy (CSV)" row, directly above #4's "Export data" row (#7).

| Key | String |
|---|---|
| `hevyImport.title` | "Import from Hevy (CSV)" |
| `hevyImport.preview.title` | "Preview import" |
| `hevyImport.preview.sessions` | "{n} workouts found" |
| `hevyImport.preview.sets` | "{n} sets" |
| `hevyImport.preview.matched` | "{n} sets matched to library exercises" |
| `hevyImport.preview.newExercises` | "{n} new custom exercises" |
| `hevyImport.preview.alreadyImported` | "{n} workouts already imported (skipped)" |
| `hevyImport.preview.folded` | "{n} warmup/failure/dropset sets imported as completed" |
| `hevyImport.preview.cardioSkipped` | "{n} cardio rows skipped — distance isn't supported yet" |
| `hevyImport.preview.quarantined` | "{n} rows set aside — tap to inspect" |
| `hevyImport.preview.metadataDropped` | "Set notes, supersets, and RPE aren't carried in this version" |
| `hevyImport.preview.unitDetected` | "Weights detected as {unit}" |
| `hevyImport.preview.unitOverride` | "Unit for {exerciseName}" |
| `hevyImport.preview.oneTime` | "Import is one-time — later Hevy edits don't sync" |
| `hevyImport.importCTA` | "Import" |
| `hevyImport.cancelCTA` | "Cancel" |
| `hevyImport.summaryLine` | "{sessions} workouts, {sets} sets imported — {skipped} already existed, {quarantined} rows skipped" |
| `hevyImport.error.notHevyExport` | "This file doesn't look like a Hevy export" |
| `hevyImport.error.applyFailed` | "Import didn't complete. Nothing was saved — try again." |
| `hevyImport.untitledSession` | "Imported workout" |

## 7. Acceptance Criteria

Fixtures under `Tests/MooreImportTests/Fixtures/*.csv` + `*.json`; `VerifyImport.mjs` runs them against an in-memory SQLite with migrations 0001, 0002, 0003, 0005, 0006, 0007_rest_fields, 0008 applied — fresh DB per fixture, JS mirror of parser + engine + DAO apply + PR re-derivation.

| # | Fixture | Input | Expected | Cites |
|---|---|---|---|---|
| V1 | `01-hundred-sessions` | Generated 100-session / 900-row kg export (3 exercises × 3 sets per session; 2 library matches + 1 miss) | Parses with zero quarantine; exactly 100 WorkoutSessions grouped by (start_time, title), 900 CompletedSets, 1 new custom exercise; second import is a counted no-op; PR rows seeded for all three exercises | BR-005, BR-013, BR-016 |
| V2 | `02-unit-detection` | kg file; lb file; dual-column file | kg detected from `weight_kg`; lb from `weight_lbs`; dual → kg wins + warning; stored actuals exact (no conversion when file=target) | BR-010 |
| V3 | `03-exercise-matching` | "Barbell Bench Press", "Squat (Barbell)", "Bench Press (Dumbbell)", "My Custom Lift", whitespace/case variant of a pre-existing custom | Primary match links the built-in; secondary strips `(Barbell)` and matches on name+equipment; "Bench Press (Dumbbell)" (no bare "Bench Press" in library) and "My Custom Lift" create customs with `isCustom=1`; the existing-custom variant matches, never double-creates | BR-009 |
| V4 | `04-grouping` | Non-contiguous interleaved rows; same start_time + different titles; same title + different days | 4 sessions; set counts + sortOrder correct per group; contiguity never assumed | BR-005, BR-007 |
| V5 | `05-idempotent` | Same file applied twice | First apply writes 1 session / 2 sets; second plan: 0 sessions, `sessionsAlreadyImported=1`; DB row counts unchanged; importKey UNIQUE holds | BR-013, INV-IM4 |
| V6 | `06-quarantine` | 3 valid rows + 1 unparseable start_time; separate majority-corrupt file | Row 4 quarantined with rowNumber/column/value/message, other 3 apply; majority-corrupt aborts with `notHevyExport`, DB untouched | BR-012, INV-IM2 |
| V7 | `07-superset` | Superset pair interleaved (A,B,A,B) + standalone set | sortOrder 0…4 in file order (interleaving preserved); superset_id counted in metadataDropped, never stored | BR-007, BR-011 |
| V8 | `08-empty-rows` | Blank rows interleaved + trailing empty record; header-only file | Empty rows skipped silently, valid session intact; header-only → 0 sessions, 0 sets, no error | BR-003 |
| V9 | `09-mixed-units` | kg file, one exercise overridden to lb, target kg | Non-overridden weights stored as-is; overridden exercise's values treated as lb and converted ÷2.20462 (unrounded float) | BR-010 |
| V10 | `10-timezone` | "14 Sep 2025, 17:41" at offsets +120 and −300 | startedAt ISO-8601 UTC shifts by exactly the offset; importKey carries the UTC stamp second-precision | BR-004, BR-013, BR-017 |
| V11 | `11-rpe-distance` | Rows with rpe populated; a distance-only row; duration row; weighted-duration row | rpe counted + dropped; distance-only row skipped + counted (cardio); duration row → actualDuration only (weight NULL); weighted-duration stores both | BR-006, BR-011 |
| V12 | `12-preview-counts` | Kitchen-sink file exercising every counter | Every PreviewCounts field matches exactly (sessions, sets, matched, newExercises names, folded, cardio skipped, quarantined, duplicates, empty rows, metadataDropped per key, warnings) | BR-014, INV-IM5 |
| V13 | `13-headers-edge` | Duplicate header column; Title-Case header variant ("Start Time", …) | Duplicate: first occurrence wins + warning; Title-Case parses identically to its snake_case equivalent | BR-002 |
| V14 | `14-notes-newlines` | description with literal `\n` escapes; exercise_notes populated | session.notes holds real newlines; name = title; exercise_notes counted in metadataDropped, never stored | BR-005, BR-011 |

Edge cases held: actualWeight blank/0 → NULL bodyweight (V1/V2 rows); plannedX NULL on every imported set (all fixtures); PR re-derivation seeds baselines silently — no cue path reachable from import (V1, BR-016); tombstoned library rows never match (BR-009 filter); >50% abort leaves zero writes (V6); re-import never double-creates customs (V5).

## 8. Rejected Alternatives

- **Reconstruct plans from history** (first-seen weight/reps → plannedX) → rejected: fabricates data, breaks #3's "planned is an immutable snapshot of intent"; NULL is honest (SC-foundation BR-004).
- **Map `set_type='failure'` → `status='failed'`** → rejected: Hevy's failure = taken-to-failure (a success); would poison #5 stall detection (BR-006).
- **Store superset_id / set_type / RPE on new columns now** → rejected: speculative generality; #2 says supersets are emergent, #7 bans RPE in UI; counts carry the information loss visibly.
- **Group by title alone or by contiguity** → rejected: recurring routine names collide; contiguity is unattested by any source (#15).
- **Fuzzy (±60 s) or content-hash dedup** → rejected: non-deterministic across devices / over-engineered for a one-time migration; deterministic importKey + UNIQUE index is exact (#15).
- **Partial/tolerant apply (skip bad rows mid-write)** → rejected: all-or-nothing keeps the audit trail clean; quarantine at parse time is the only skip path (INV-IM2/INV-IM3).
- **Live-path PR cues on imported sets** → rejected: import uses the maintenance path only; retroactive cue promotion is dead per SC-prs BR-009.
- **Import as sync (re-running pulls Hevy edits)** → rejected: one-time migration channel by ruling; sync is #4's cloud phase.

## 9. Downstream Effects

- **Unblocks #31 (Android port):** parser + engine are seam-1 pure functions; V1–V14 are the port-parity vectors (per #8).
- **Feeds #27 (analytics/history):** imported rows are plain CompletedSets — trends read actualX; plannedX-NULL rows are excluded from adherence deltas per the BR-006 ruling.
- **Feeds #28 (Settings):** consumes §6 keys for the Data & sync import row + preview screen.
- **Feeds #26 (PRs):** import is the first bulk consumer of the maintenance re-derivation path (BR-009) at scale.
- **Surfaced fog:** built-in library naming vs Hevy's `Name (Equipment)` convention sets the real-world match rate — the alias table is future work for the data-model owner; cardio/distance exercises remain unsupported by the data model.
