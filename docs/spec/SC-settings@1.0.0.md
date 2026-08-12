# Contract: Settings + Data & Sync

```yaml
---
contractId: "SC-settings"
version: "1.0.0"
status: frozen
date: "2026-08-13"
source: "#28"
supersedes: null
supersededBy: null
---
```

One concern, one contract: the **Settings + Data & sync surface** — where the user configures per-gym needs (weight unit, rest defaults), keeps body metrics, manages exercise tombstones, and owns their data (full-database export at any time). Everything here is configuration and custody: this contract adds **zero business logic to the training path** — it edits the same `app_setting` rows `SC-rest@1.0.0` resolves from, renders stored weights through a display-only unit lens, and copies the database file verbatim.

Consumes `SC-foundation@1.0.0` (schema + invariants, migrations 0001–0003; the `body_metric` table of 0001 which this contract rebuilds in §3d; the `foundation.db.*` copy keys of §6 which SC-foundation explicitly defers to this contract), `SC-exercises@1.0.0` (tombstone/restore of custom exercises over 0001's `exercise` columns only), `SC-rest@1.0.0` (the `app_setting` singleton table and the two rest-default keys created by `0007_rest_fields.sql` — **verified present in this worktree**; this contract adds no duplicate `app_setting` migration). Adds **one additive migration**, `0009_body_metrics.sql` (§3d), which rebuilds `body_metric` to admit `measurement` entries (free label + free unit) — behavior-additive, no row ever lost, same table-rebuild pattern as `0007_progression_full.sql` / `0008_personal_records.sql`.

## 2. State Machine

Settings is transactional configuration; it carries one micro-machine — the **export flow** — because a full-file copy is the only long-running act on this surface.

| State | Meaning | Entered by | Exits |
|---|---|---|---|
| `exportIdle` | No export in flight; the Export backup affordance is enabled. | Initial; terminal transitions below. | → `exportPreparing` on `exportRequested`. |
| `exportPreparing` | Manifest being built (§5 `buildExportManifest`); table counts incl. tombstones read. | ← `exportIdle` via `exportRequested`. | → `exportWriting(manifest)` on manifest built. → `exportFailed(reason)` on read error. |
| `exportWriting(manifest)` | Full SQLite file copy in progress (BR-008). | ← `exportPreparing`. | → `exportCompleted(manifest, fileName)` on copy done. → `exportFailed(reason)` on write error. |
| `exportCompleted(manifest, fileName)` | `.moore-backup` file handed to the share sheet; toast `settings.dataSync.exportedToast`. | ← `exportWriting`. | → `exportIdle` on dismiss. |
| `exportFailed(reason)` | `foundation.db.*` fallback copy per SC-foundation §6 severity rules. | ← `exportPreparing` / `exportWriting`. | → `exportIdle` on dismiss. |

**Invariants**

- **INV-ST1 (unit toggle never writes data):** a unit change writes exactly one `app_setting` row (`weightUnit`). No weight value in any other table is rewritten, ever (BR-001).
- **INV-ST2 (canonical kg):** every weight column that carries no unit of its own (`planned_set.plannedWeight`, `completed_set.plannedWeight`/`actualWeight`) is canonical **kg**. `body_metric` rows carry their own `unit`.
- **INV-ST3 (export completeness):** an export copy contains every table — including `__legacy_*` rebuild remnants — and every row, tombstones included; `plannedX` columns pass through byte-verbatim. Nothing is filtered, rewritten, or vacuumed (BR-008).
- **INV-ST4 (restore is the inverse of tombstone):** restoring a tombstoned custom exercise sets `deletedAt = NULL` and bumps `updatedAt` — nothing else changes. No row is re-inserted, no history is touched (BR-010).
- **INV-ST5 (dormant surfaces have no write path):** the cloud-sync toggle and the Hevy-import entry write no row anywhere. They render state, nothing else (BR-011, BR-012).
- **INV-ST6 (closed body-metric vocabulary post-0009):** writers persist `kind ∈ {bodyWeight, bodyFat, measurement}` only. Legacy `weight` rows are remapped to `bodyWeight` by 0009; the CHECK rejects the legacy spelling afterwards.

## 3. Data Schema

Base shapes come from #19's 0001–0003, #21's 0005–0006, #23's `0007_rest_fields.sql`, #24's `0007_progression_full.sql`, #26's 0008. **This contract creates one migration** (§3d) and no other schema change.

### (a) Settings storage — `app_setting` singleton rows

`app_setting` exists as of `0007_rest_fields.sql` (SC-rest §3d). This contract adds **one key**, managed by the DAO (read-side fallback, upsert-on-change), and edits the two existing rest keys:

| key | value | Owner | Seeded by |
|---|---|---|---|
| `defaultRestCompoundSec` | `'180'` | SC-rest (§3a level 4) | `0007_rest_fields.sql` (INV-S2 there) |
| `defaultRestIsolationSec` | `'90'` | SC-rest (§3a level 4) | `0007_rest_fields.sql` (INV-S2 there) |
| `weightUnit` | `'kg'` \| `'lb'` | this contract | **absent ⇔ `'kg'`** — read-side fallback (BR-014); row created on first change |

> **#23 drift note:** `0007_rest_fields.sql` was authored by `feat/23-rest-cues`. In worktrees where it is absent from history, the equivalent additive step would be a migration creating `app_setting` with the two #9 fields; **in this worktree the file exists** (`Sources/MooreRest/Migrations/0007_rest_fields.sql`), so no duplicate migration is added here.

### (b) `body_metric` canonical shape (post-0009)

```
BodyMetric = {
  id         TEXT PK,
  kind       TEXT NOT NULL CHECK (kind IN ('bodyWeight','bodyFat','measurement')),
  label      TEXT,                    -- 0009 add; free name, REQUIRED for kind='measurement', NULL otherwise
  value      REAL NOT NULL,           -- > 0; bodyFat additionally ≤ 100 (BR-006)
  unit       TEXT NOT NULL,           -- legality per kind below; free TEXT post-0009
  recordedAt TEXT NOT NULL,           -- ISO-8601 UTC; the timeline key (SC-foundation BR-005)
  createdAt  TEXT NOT NULL,
  updatedAt  TEXT NOT NULL,
  deletedAt  TEXT                     -- tombstone per SC-foundation INV-3
}
```

Unit legality per kind (BR-006, application-enforced): `bodyWeight ∈ {kg, lb}`; `bodyFat = pct`; `measurement` = any non-empty unit string as entered (typically `cm` / `in`). 0001's legacy `kind='weight'` rows are remapped to `bodyWeight` by the 0009 copy (§3d); the legacy `__legacy_0001` table preserves the pre-remap rows (INV-ST3 keeps it in every export).

### (c) Invariants (additive to SC-foundation §3c)

1. INV-1..INV-7 inherited unchanged from `SC-foundation@1.0.0` §3c. No exceptions.
2. **INV-ST1..INV-ST6** as listed in §2.
3. **INV-ST7 (additive-only settings keys):** `app_setting` keys are never renamed or removed across versions, only added (inherits SC-rest INV-S1). `weightUnit` absent ⇔ `'kg'` is a read rule, not a row deletion.

### (d) Migration `0009_body_metrics.sql`

Behavior-additive table rebuild (SC-prs §3d precedent): no row ever lost.

1. `CREATE TABLE IF NOT EXISTS body_metric_v2` with the §3b shape (`label` column added; `kind` CHECK admits `measurement` and drops the legacy `weight` synonym; `unit` widened to free TEXT).
2. Copy legacy rows: `kind: 'weight' → 'bodyWeight'` (INV-ST6 remap); everything else verbatim; `label = NULL`.
3. `ALTER TABLE body_metric RENAME TO body_metric__legacy_0001`; `ALTER TABLE body_metric_v2 RENAME TO body_metric`.
4. Rebuild the trend indexes: `body_metric_kind_recorded_idx(kind, recordedAt DESC)` and `body_metric_recorded_idx(recordedAt DESC)`, both `WHERE deletedAt IS NULL` (BR-007 list path).

No renames/drops of columns, no edits to 0001–0008. The `app_setting` table is **not** touched (already exists via 0007).

## 4. Business Rules

- **BR-001 (units are display-only).** The `weightUnit` toggle changes rendering and entry conversion **only**. No migration, no batch update, no write of any kind touches stored weight values when the unit changes (INV-ST1). Existing data is unaltered by definition — the toggle writes one settings row.
- **BR-002 (conversion math + precision).** `lb = kg × 2.20462`; `kg = lb ÷ 2.20462`. Display rounds to **1dp** half-away-from-zero; storage/entry-conversion rounds to **2dp** half-away-from-zero. The ratio constant is spelled `2.20462` everywhere (engine + JS mirror), never re-derived.
- **BR-003 (entry respect).** Entry affordances render the active unit. An entered value is converted to canonical kg (2dp) **before** insert/update (BR-002); the stored value is always kg for unit-less weight columns (INV-ST2). Entering `180 lb` stores `81.65` kg; displayed back in lb that reads `180.0 lb`.
- **BR-004 (body-metric display).** A `body_metric` row carries its own `unit`; display converts row-unit → active unit at 1dp when both are weight units (`kg`/`lb`). `pct` rows are never converted (no weight dimension). A `180 lb` bodyWeight row under a kg setting displays `81.6 kg`.
- **BR-005 (rest defaults edit).** The rest-defaults row edits exactly the two `app_setting` keys from SC-rest §3a level 4 (`defaultRestCompoundSec`, `defaultRestIsolationSec`), upsert-on-change, `updatedAt` bumped per SC-foundation INV-2. The settings surface never *resolves* rest durations — SC-rest BR-001's hierarchy consumes these rows unchanged; a changed default affects the next auto-rest but never a persisted `PlannedSet.restDurationSec` override (SC-rest level 1 beats level 4).
- **BR-006 (body metrics CRUD).** Create validates: `kind` in the closed vocabulary (INV-ST6); `label` required for `measurement`; unit legality per kind (§3b); `value > 0`; `bodyFat ≤ 100`. Reject = error, no partial write. Update bumps `updatedAt` (INV-2). Delete is a tombstone (SC-foundation BR-003) — default lists filter `deletedAt IS NULL`; raw scans still see the row.
- **BR-007 (trend list, no charts).** The body-metrics list renders date-descending on `recordedAt` (SC-foundation BR-005 timeline key), optionally filtered by kind. No aggregation is computed or persisted (SC-foundation INV-5: derived, never persisted); v1 ships **no charting**.
- **BR-008 (export = full SQLite file copy).** Export produces a complete copy of the database file via the SQLite backup API — every table (`__legacy_*` included), every row (**tombstones included**), every column (`plannedX` verbatim). Nothing is filtered or rewritten (INV-ST3). File naming: `moore-<exportedAt>.moore-backup` where `<exportedAt>` is the ISO-8601 UTC instant with `:` replaced by `-` (filename-safe), e.g. `moore-2026-08-13T09-30-00Z.moore-backup`. The copy imports cleanly back into the same app version (identical schema shape).
- **BR-009 (export manifest).** Before the copy, the manifest enumerates the ten core tables — `folder`, `exercise`, `routine`, `planned_set`, `workout_session`, `completed_set`, `personal_record`, `body_metric`, `progression_scheme`, `app_setting` — with total row count and tombstone count each, plus `includesTombstones = true`, `includesPlannedColumns = true`, `format = sqlite-file-copy`. The manifest is the honest label on the share sheet.
- **BR-010 (tombstone management).** The list shows `exercise` rows with `isCustom = 1 AND deletedAt IS NOT NULL`, ordered `deletedAt DESC, name ASC`. Built-in (non-custom) tombstones never appear — they are not user-owned. **Restore** clears `deletedAt` (sets NULL) and bumps `updatedAt` — the entire state change (INV-ST4). Restoring never re-inserts; the row's id, name, and history are untouched.
- **BR-011 (cloud sync permanently greyed).** The sync toggle renders disabled, forever at v1: `enabled = false`, `greyed = true`, no handler, no write path (INV-ST5). Copy: `settings.cloudSync.coming` = "Coming after self-validation gate" — the #4 trigger condition, verbatim in spirit; the info icon links to #4.
- **BR-012 (Hevy import entry stub).** The Import-from-Hevy entry point renders on this surface but is a **stub**: `enabled = false`, `blockedByTicket = #30`, copy keyed (§6). Invoking it writes no row (INV-ST5). The real import lands with #30 on this seam.
- **BR-013 (#14 empty-state copy wired).** All nineteen #14 resolution keys (§6) resolve to their exact strings on this surface's copy table — Home, Active Workout, History, Analytics, picker. A key rendering empty or literal is a contract violation. The eight `foundation.db.*` keys of SC-foundation §6 are wired here as well (that contract names SC-settings as the wiring owner).
- **BR-014 (settings read totality).** `fetchSettings` is total: a missing `weightUnit` row reads `'kg'`; missing/invalid rest rows fall back to SC-rest's seeded defaults (`180`/`90`). The settings screen renders on a fresh database with zero writes.

## 5. API Contract

`MooreSettings` module. Engine is seam-1 (pure, Foundation only, closed-form); DAO is seam-2 (GRDB). No SwiftUI — surfaces bind these value types.

```swift
/// Display unit (§3a). Storage stays canonical kg (INV-ST2).
public enum WeightUnit: String, Codable, CaseIterable, Sendable { case kg, lb }

/// Aggregate snapshot the Settings screen binds (BR-014: always total).
public struct AppSettingsSnapshot: Equatable, Sendable {
    public var weightUnit: WeightUnit                  // absent row ⇔ .kg
    public var defaultRestCompoundSec: Int             // 180 fallback (SC-rest)
    public var defaultRestIsolationSec: Int            // 90 fallback
    public static let `default`: AppSettingsSnapshot   // .kg / 180 / 90
}

public enum SettingsEngine {
    // MARK: Unit conversion (BR-002/BR-003/BR-004) — pure
    public static let kgPerLbRatio: Double             // 2.20462
    public static func kgToLb(_ kg: Double) -> Double
    public static func lbToKg(_ lb: Double) -> Double
    public static func roundDisplay(_ v: Double) -> Double   // 1dp, half-away-from-zero
    public static func roundStorage(_ v: Double) -> Double   // 2dp, half-away-from-zero
    public static func displayValue(rawKg: Double, unit: WeightUnit) -> Double
    public static func displayString(rawKg: Double, unit: WeightUnit) -> String   // "220.5 lb"
    public static func entryToStorage(_ entered: Double, unit: WeightUnit) -> Double  // → kg 2dp
    public static func displayBodyMetric(value: Double, rowUnit: String,
                                         target: WeightUnit) -> Double  // pct passes through (BR-004)

    // MARK: Export manifest (BR-008/BR-009)
    public struct TableStats: Equatable, Sendable { public var table: String; public var rowCount: Int; public var tombstoneCount: Int }
    public struct ExportManifest: Equatable, Sendable {
        public var fileName: String            // moore-<ts>.moore-backup
        public var exportedAt: String          // ISO-8601 UTC
        public var format: String              // "sqlite-file-copy"
        public var includesTombstones: Bool    // always true (INV-ST3)
        public var includesPlannedColumns: Bool// always true
        public var tables: [TableStats]        // the ten core tables, BR-009 order
    }
    public static let backupFileSuffix: String        // ".moore-backup"
    public static let coreTableNames: [String]        // BR-009's ten
    public static func backupFileName(exportedAt: String) -> String
    public static func buildExportManifest(tableStats: [TableStats], exportedAt: String) -> ExportManifest

    // MARK: Tombstone listing (BR-010) — pure filter/sort
    public struct ExerciseTombstoneRow: Equatable, Sendable {
        public var id: String; public var name: String
        public var isCustom: Int; public var deletedAt: String?
    }
    public static func tombstonedCustomExercises(from rows: [ExerciseTombstoneRow]) -> [ExerciseTombstoneRow]

    // MARK: Dormant surfaces (BR-011/BR-012)
    public struct CloudSyncStatus: Equatable, Sendable {
        public var enabled: Bool; public var greyed: Bool
        public var copyKey: String; public var infoIssue: String
    }
    public static let cloudSyncStatus: CloudSyncStatus  // false / true / settings.cloudSync.coming / #4
    public struct HevyImportEntry: Equatable, Sendable {
        public var enabled: Bool; public var blockedByTicket: String; public var copyKey: String
    }
    public static let hevyImportEntry: HevyImportEntry  // false / #30 / settings.dataSync.importHevy

    // MARK: Body-metric validation (BR-006) — pure
    public enum BodyMetricValidationError: Error, Equatable, Sendable {
        case invalidKind(String); case measurementRequiresLabel
        case invalidUnit(kind: String, unit: String); case invalidValue(String)
    }
    public static func validateBodyMetric(kind: String, label: String?,
                                          value: Double, unit: String) -> BodyMetricValidationError?

    // MARK: Keyed copy (BR-013, §6)
    public static let emptyStateCopy: [String: String]     // #14's nineteen keys, exact
    public static let foundationDbCopy: [String: String]   // SC-foundation §6's eight keys, exact
    public static let settingsCopy: [String: String]       // this surface's own keys (§6)
}

/// GRDB-backed seam-2 (file: SettingsDAO.swift). Assumes the full migration
/// chain incl. 0007_rest_fields + 0009_body_metrics has been applied.
public struct SettingsDAO: Sendable {
    public init(dbQueue: DatabaseQueue)

    // Settings (BR-001, BR-005, BR-014)
    public func fetchSettings() throws -> AppSettingsSnapshot
    public func setWeightUnit(_ unit: WeightUnit, at now: String) throws
    public func updateRestDefaults(compoundSec: Int?, isolationSec: Int?, at now: String) throws

    // Body metrics CRUD (BR-006/BR-007)
    public func addBodyMetric(kind: String, label: String?, value: Double, unit: String,
                              recordedAt: String, at now: String) throws
    public func listBodyMetrics(kind: String?) throws -> [SettingsBodyMetric]  // recordedAt DESC, live
    public func updateBodyMetric(id: String, value: Double, unit: String, label: String?,
                                 recordedAt: String, at now: String) throws
    public func softDeleteBodyMetric(id: String, at now: String) throws

    // Tombstone management (BR-010)
    public func listTombstonedCustomExercises() throws -> [TombstonedExercise]
    public func restoreExercise(id: String, at now: String) throws

    // Data & sync (BR-008/BR-009)
    public func exportSelectDumps() throws -> [SettingsEngine.TableStats]   // every table incl. __legacy_*
    public func exportManifest(exportedAt: String) throws -> SettingsEngine.ExportManifest
    public func exportFullCopy(toPath destinationPath: String) throws       // full SQLite file copy
}
```

**Seams under test:**
- **Seam-1 (logic):** `SettingsEngine` conversion/manifest/tombstone/validation/copy — verified by the JS mirror in `VerifySettings.mjs` against `Tests/MooreSettingsTests/Fixtures/*.json` (deterministic, platform-free).
- **Seam-2 (persistence):** `SettingsDAO` round-trips over fresh SQLite per fixture, full migration chain applied — including the **backup round-trip**: export copy re-opened, per-table row counts incl. tombstones match, and the SHA-256 content hash of the copy equals the original's (AC "backup round-trip DB hash matches").

## 6. UI Copy

Keyed per #6; code references keys, never literals. Voice per #17 (declarative, factual, no exclamation marks). Dynamic values use `{placeholder}`.

**Settings surface (this contract's own keys)**

| Key | String |
|---|---|
| `settings.title` | "Settings" |
| `settings.units.title` | "Units" |
| `settings.units.weight` | "Weight unit" |
| `settings.restDefaults.title` | "Rest defaults" |
| `settings.restDefaults.compound` | "Compound lifts" |
| `settings.restDefaults.isolation` | "Isolation" |
| `settings.restDefaults.value` | "{n}s" |
| `settings.bodyMetrics.title` | "Body metrics" |
| `settings.bodyMetrics.addCta` | "Add entry" |
| `settings.bodyMetrics.empty` | "No entries yet" |
| `settings.bodyMetrics.trendTitle` | "Trend" |
| `settings.dataSync.title` | "Data & sync" |
| `settings.dataSync.exportCta` | "Export backup" |
| `settings.dataSync.exportedToast` | "Backup saved: {fileName}" |
| `settings.dataSync.importHevy` | "Import from Hevy" |
| `settings.dataSync.importHevyBlocked` | "Available after import ships" |
| `settings.cloudSync.title` | "Cloud sync" |
| `settings.cloudSync.coming` | "Coming after self-validation gate" |
| `settings.tombstones.title` | "Deleted custom exercises" |
| `settings.tombstones.restoreCta` | "Restore" |
| `settings.tombstones.empty` | "Nothing deleted" |

**#14 empty-state copy — wired verbatim from #14's resolution comment (BR-013)**

| Key | String |
|---|---|
| `home.empty_title` | "No routines yet" |
| `home.empty_sub` | "Routines are your gym days. Create one and your next workout is one tap to start." |
| `home.empty_cta` | "Create your first routine" |
| `home.streak_label` | "{n}-day streak" |
| `home.startEmpty_cta` | "Start empty" |
| `activeWorkout.emptyList_line` | "No sets yet" |
| `activeWorkout.addExercise_cta` | "+ Add exercise" |
| `activeWorkout.startEmpty_help` | "Add an exercise to start logging" |
| `history.empty_title` | "No sessions yet" |
| `history.empty_sub` | "Your gym visits will live here." |
| `history.empty_cta` | "Start a workout" |
| `analytics.empty_title` | "Nothing to graph yet" |
| `analytics.empty_sub` | "Log 3 sessions to start seeing trends." |
| `analytics.empty_cta` | "Log your first session" |
| `analytics.hint_body` | "Every workout builds your stats." |
| `picker.search_empty_title` | "No matches" |
| `picker.search_empty_sub` | "Check spelling or create it custom." |
| `picker.createCustom_cta` | "Create custom exercise" |
| `picker.browse_hint` | "Or scroll to browse" |

**SC-foundation §6 fatal-recovery keys (wiring deferred to this contract)** — the eight `foundation.db.*` keys ship verbatim from SC-foundation §6 (`fatalTitle`, `fatalBody`, `fatalAction`, `migrationFailedTitle`, `migrationFailedBody`, `migrationFailedAction`, `corrupted`, `unknownError`).

## 7. Acceptance Criteria

Fixtures under `Tests/MooreSettingsTests/Fixtures/*.json`; `VerifySettings.mjs` runs them against fresh in-memory SQLite with the full migration chain (0001–0003, 0005–0008, 0009; 0004 skipped per SC-rest's drift note) applied, one DB per fixture, plus the JS mirror of `SettingsEngine`.

| # | Setup | Action sequence | Expected | Cites |
|---|---|---|---|---|
| V1 | Engine only. | `kgToLb(100)`, `lbToKg(220.462)`, display strings at both units. | `220.462` lb; back to `100`; display `220.5 lb` / `100.0 kg` (1dp). | BR-002 |
| V2 | Engine only. | Entry `180 lb` → storage; storage `81.65` kg → lb display. | Stores `81.65` (2dp); displays `180.0 lb`. Round-trip stable. | BR-003, BR-002 |
| V3 | DB seeded: completed_set actualWeight=100, body_metric 82.4 kg. | Snapshot tables → `setWeightUnit(lb)` → displays → `setWeightUnit(kg)`. | Displays flip (`100.0 kg` → `220.5 lb` → `100.0 kg`; 82.4 kg → `181.7 lb`); **both tables byte-identical before/after** (display-only). | BR-001, BR-004, INV-ST1 |
| V4 | Post-migrate defaults 180/90. | `updateRestDefaults(compoundSec: 150)` → fetch. | compound=150, isolation=90; `updatedAt` bumped; row upserted, not duplicated. | BR-005, SC-rest INV-S1 |
| V5 | User value 150 present. | Re-apply the `INSERT OR IGNORE` seed tail of 0007 → fetch. | Still 150 — re-migration never resets a user value. | BR-005, SC-rest INV-S2 |
| V6 | Empty body_metric. | Add weight 82.4 kg @08-10, bodyFat 15.5 pct @08-11, measurement "Waist" 84 cm @08-09, weight 181 lb @08-12 → list all; list kind=weight. | All-list date-descending: 08-12 / 08-11 / 08-10 / 08-09; weight-filter keeps both weight rows desc; measurement row carries label "Waist". | BR-006, BR-007 |
| V7 | Fresh DB pre-0009 holding a `kind='weight'` row. | Apply 0009. | Row remapped to `bodyWeight`; `label` column exists; `measurement`+`cm` insert accepted; `kind='weight'` insert now rejected by CHECK; `body_metric__legacy_0001` preserved with the pre-remap row. | §3d, INV-ST6 |
| V8 | Live bodyWeight row. | Update value (updatedAt bumped) → soft-delete → list; raw scan. | Update visible, `updatedAt` bumped; deleted row absent from list, present in raw scan with `deletedAt` set. Invalid inputs (bad kind / measurement-without-label / wrong unit / value ≤ 0 / bodyFat > 100) all rejected with no partial write. | BR-006, INV-ST6 |
| V9 | All ten core tables seeded incl. tombstones + populated plannedX + NULL plannedX rows. | `buildExportManifest(exportedAt)`. | fileName `moore-2026-08-13T09-30-00Z.moore-backup`; format `sqlite-file-copy`; `includesTombstones=true`; `includesPlannedColumns=true`; every core table listed with exact total + tombstone counts. | BR-008, BR-009 |
| V10 | Same seeded DB. | Full file copy → re-open copy. | Every table's row count (tombstones included) matches; SHA-256 content hash of copy == original; `integrity_check` ok; copy's per-table column shape == a freshly-migrated DB's (imports cleanly into same version). | BR-008, INV-ST3 |
| V11 | Exercises: built-in live, built-in tombstoned, custom live, custom tombstoned ×2 (distinct deletedAt). | List tombstoned → restore newer → list → restore older → list. | List = the two customs only, deletedAt-desc (built-ins never listed); each restore clears `deletedAt` + bumps `updatedAt`; restored rows fetch as live; final list empty. | BR-010, INV-ST4 |
| V12 | — | Read cloud-sync status. | `enabled=false`, `greyed=true`, copy key resolves to "Coming after self-validation gate", info → #4; zero rows written anywhere. | BR-011, INV-ST5 |
| V13 | Sessions seeded. | Invoke Hevy-import entry. | `enabled=false`, `blockedByTicket=#30`, copy keyed; session count unchanged (stub writes nothing). | BR-012, INV-ST5 |
| V14 | — | Resolve copy tables. | All nineteen #14 keys present with exact strings; all eight `foundation.db.*` keys present; every settings-surface key non-empty. | BR-013, §6 |

Edge cases to hold: `weightUnit` row absent ⇔ kg with zero writes (BR-014); export manifest on an empty database still lists all ten tables at count 0; restoring an already-live exercise is a no-op, not an error; `pct` rows never pass through weight conversion (BR-004).

## 8. Rejected Alternatives

- **Unit toggle rewrites stored weights** → rejected: violates display-only rule; a lossy batch rewrite of CompletedSet on a gym-floor toggle is the exact silent-data-mutation class every other contract bans. Canonical kg + render-time conversion keeps storage immutable (BR-001/INV-ST1).
- **Per-row unit columns on completed_set/planned_set** → rejected: doubles every write path for zero v1 need; body_metric already carries units where mixed units are legitimate (different tracking devices). Hevy's own export stores kg-less raw numbers.
- **Storing the display unit as a column on each weight row** → variant of the above; same rejection.
- **JSON/CSV export instead of full SQLite copy** → rejected: the ticket's data-custody promise is "every CompletedSet row incl. tombstoned ones and full plannedX columns"; a file copy is the only export that cannot lose a column a later version added (INV-ST3, BR-008). CSV would re-create the #15 import-loss class at the export seam.
- **Vacuuming tombstones out of the backup** → rejected: tombstones are sync-legal rows (SC-foundation BR-003); a backup that drops them would resurrect deletes on a future cloud restore (#4).
- **Live cloud-sync toggle that persists a disabled flag** → rejected: a stored flag implies a write path and a future migration obligation; the dormant surface renders from a constant (INV-ST5, BR-011).
- **Implementing Hevy import here because the UI lives here** → rejected: #30 owns import semantics (dedupe, matching); this contract ships the entry stub only (BR-012).
- **Charts on the body-metrics trend** → rejected at ticket: v1 is a date-descending list; charting is unbounded fog (BR-007).
- **Editing rest defaults anywhere but `app_setting`** → rejected: SC-rest §3a fixes level-4 storage; a second copy would fork the hierarchy's source of truth (BR-005).
- **Listing built-in exercise tombstones for restore** → rejected: built-ins are library rows the user does not own; restoring them is meaningless state churn (BR-010).

## 9. Downstream Effects

- **Feeds #7 (screen blueprint):** the Settings surface's five groups (Units, Rest defaults, Body metrics, Data & sync incl. tombstones) and every §6 key are the wireframe's binding targets.
- **Feeds #30 (Hevy import):** lands on `SettingsEngine.hevyImportEntry`'s exact seam — the entry point, copy key, and surface are frozen here; #30 implements the handler behind it.
- **Feeds #4 (cloud activation):** when the self-validation gate passes, the greyed toggle is the activation surface; the `weightUnit` key's additive pattern (BR-014/INV-ST7) is the template for sync-era settings keys. The export file is the pre-sync custody story (#4's v1 backup requirement).
- **Feeds #27 (analytics):** body-metric rows (post-0009 shape, `recordedAt` timeline key) are the bodyweight-trend source; analytics derives, never persists (SC-foundation INV-5).
- **Feeds #22/#23 consumers:** nothing changes — rest resolution reads the same `app_setting` rows (SC-rest BR-001); the settings surface only edits level 4.
- **Feeds #8 (Android port):** frozen at v1.0.0; the JS mirror of `SettingsEngine` is byte-identical logic, the `2.20462` ratio and `.moore-backup` naming are vocabulary, and 0009 ships as a shared `.sql` artifact like every other migration.
