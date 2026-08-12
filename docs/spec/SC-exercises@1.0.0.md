# Contract: Exercise Library + Picker

```yaml
---
contractId: "SC-exercises"
version: "1.0.0"
status: frozen
date: "2026-08-11"
source: "#20"
supersedes: null
supersededBy: null
---
```

Two concerns, one contract: (1) the canonical catalog of exercises the app knows about (built-in seed pack + user customs), with its lifecycle and matching rules; (2) the picker sheet through which every other surface chooses an exercise. A unit tested against this contract never needs to know whether an exercise came from the seed file, was typed by the user, or arrived via CSV import (#30) — those are construction details hidden by the lifecycle states below.

## 2. State Machine

### 2a. Exercise lifecycle

Every `Exercise` row is in exactly one state at a time.

| State | Meaning | Entered by | Exits |
|---|---|---|---|
| `builtIn` | Seeded from `builtin-library.json` at first launch. `isCustom = 0`. Read-only semantics: name/category/defaultMetric/equipment are not user-editable. | Seed-install on first open; re-install on app update (idempotent INSERT-OR-IGNORE keyed by row `id`). | → `tombstoned` via *user hide action* (soft "delete" of a built-in). Never hard-deleted. |
| `active` | A custom exercise (`isCustom = 1`) that is not tombstoned. Listable, pickable, editable (name + defaultRestSec), deletable. | → via *create-custom* (§5) or via *import-miss-create* (#30/cites #15). | → `tombstoned` via user delete action. Never hard-deleted. |
| `tombstoned` | Row carries `deletedAt IS NOT NULL`. Not listable, not searchable, not pickable. **The row remains** so any historic `CompletedSet.exerciseId` that references it still resolves its name (INV-L3). | ← any state via delete action. | → `active` via *restore* action (custom only). No transition back to `builtIn` — a tombstoned built-in stays tombstoned until the user un-hides it, at which point it returns to `builtIn`. |

### 2b. Picker overlay

The picker is a transient modal sheet (Tier 2 per #17; no glass on the money screen rule does not apply here because the picker is not the money screen). Its states are named for tests:

| State | Meaning | Entered by | Exits |
|---|---|---|---|
| `idle` | Search field empty; the body shows category browse (a pinned scroll-hint list of categories, each jump-to-able). | Picker present; search cleared. | → `searching` on first non-whitespace search text. → `selected` on any cell tap. |
| `searching` | Search text non-empty; body shows filtered rows (matching per BR-003/BR-004), grouped by category. | User types any non-whitespace character. | → `searching` on each keystroke; → `noResults` when result set is empty; → `selected` on row tap; → `creating` on last-row CTA tap; → `idle` on text clear. |
| `noResults` | Result set is empty for the current query. Body shows the §6 `picker.noMatches` line and the `picker.createCustom` CTA as the last row. | Auto from `searching` when the filter set is empty. | → `searching` on any keystroke that produces a non-empty filter set; → `creating` on CTA tap; → `idle` on text clear. |
| `creating` | Inline create-custom form is open (name field pre-seeded with the search text, category picker defaulted to the first category or to the currently-selected category filter if one is active, confirm button disabled until name is non-empty after BR-001 normalization). | Tap on `picker.createCustom` CTA in either `searching` or `noResults`. | → `created` on confirm; → `searching` on cancel; → `idle` on search-text clear (cancels creation). |
| `created` | A new custom Exercise was inserted in the same atomic write as the user's confirm tap. Picker immediately selects it and emits the callback (§5). | ← `creating` confirm. | → `selected` (one-way, same tick). |
| `selected` | Terminal: an exercise has been chosen; the sheet is dismissing and the callback is firing. | Row tap from any search state; auto from `created`. | — (terminal; sheet dismisses). |

**Transition matrix** (picker):

| from \ to | searching | noResults | creating | created | selected | idle |
|---|---|---|---|---|---|---|
| idle | text-entered | `-` | `-` | `-` | tap-row | `-` |
| searching | keystroke | filter-empty | tap-createCTA | `-` | tap-row | text-cleared |
| noResults | keystroke(nonempty-match) | keystroke | tap-createCTA | `-` | `-` | text-cleared |
| creating | cancel | `-` | `-` | confirm | `-` | text-cleared |
| created | `-` | `-` | `-` | `-` | auto-select | `-` |
| selected | `-` | `-` | `-` | `-` | `-` | `-` |

(Dashes = illegal transition.)

**Invariants**

- **INV-P1:** `picker.createCustom` CTA is the last row when visible, and only when a search query is non-empty after trim.
- **INV-P2:** From `noResults` there is no path to `selected`; the user must type or create.
- **INV-P3:** `creating` pre-seeds the name field with the current search text *verbatim* (pre-normalization) so the user sees what they typed — normalization (BR-001) applies only to the matching/dedupe key, not to the display name.
- **INV-P4:** On `created`, the callback emits the new ID in the same event as the dismissal; the parent surface never has to re-query to learn the new ID.

**Lifecycle invariants**

- **INV-L1:** `isCustom = 0` rows are never mutated in place by user action (no rename, no category change, no equipment change).
- **INV-L2:** `deletedAt` is the only delete mechanism; rows are never `DELETE FROM exercise`d.
- **INV-L3:** Any tombstoned or non-tombstoned row may be dereferenced from `CompletedSet.exerciseId` and always yields its name — name resolution is unaffected by tombstone state (Source: #3 invariant 2).
- **INV-L4:** Two distinct non-tombstoned rows may never share the same BR-001 normalized name *if both are custom*; a custom may share a normalized name with a built-in only if the built-in is tombstoned (BR-005's restore-window).

## 3. Data Schema

Base table shape comes from #19's migration 0001 (the `exercise` table exists with `id`, `createdAt`, `updatedAt`, `deletedAt`). This contract adds only **additive columns** via migration `0004_exercise_library.sql` (§3c).

### (a) Entity table

| Entity | Role | Key relationships |
|---|---|---|
| `Exercise` | Canonical catalog row — built-in *or* custom | `CompletedSet.exerciseId → Exercise.id` (defined by #3); consumed read-only by the picker. |
| `BuiltinLibrarySeed` | Not a DB entity; a JSON file in the app bundle. Schema-of-record for the seed. | Read at first launch by ExerciseLibrarySeeder (§5/BR-006). |

### (b) Field contracts

```
Exercise                    = { id, isCustom: 0|1, name, nameNormalized, category, defaultMetric: reps|duration,
                                equipment, defaultRestSec?, createdAt, updatedAt, deletedAt? }

ExerciseCategory enum       = { chest, back, shoulders, biceps, triceps, forearms, core,
                                quads, hamstrings, glutes, calves, fullBody, cardio, other }

ExerciseEquipment enum      = { barbell, dumbbell, cable, machine, bodyweight, smith, plate,
                                band, kettlebell, ezBar, trapBar, medicineBall, sled, other }

BuiltinLibrarySeed          = { schemaVersion: 1, exercises: [BuiltinExercise] }
BuiltinExercise             = { id, name, category, defaultMetric: reps|duration, equipment }
                              // id is a fixed lowercase kebab-case slug (see BR-006),
                              // NOT a UUID, so cross-install reference is stable.
```

Notes:
- `id` for custom exercises is a UUID (TEXT).
- `id` for built-in exercises is a stable slug (e.g. `"barbell-bench-press"`) hardcoded in the seed; see BR-006.
- `nameNormalized` is materialized at write time (BR-001) so indexes on it stay trivial.
- `defaultRestSec` is `NULL` for every seeded built-in (no opinion); it exists so a user or a routine (#21) can declare an override per #9. Custom exercises may set it at creation; the field is NOT editable for built-ins via the picker. #9 owns the fallback chain; this contract only owns the column.
- `defaultMetric` gates picker display (reps badge vs duration badge); it does not gate set entry (a "duration" exercise may still record reps in a CompletedSet — that is #22's surface's concern, not this contract's).

### (c) Invariants + derivation rules

1. **Immutability:** For `isCustom = 0`: `id`, `name`, `nameNormalized`, `category`, `defaultMetric`, `equipment`, `createdAt` are frozen after write. Only `updatedAt` and `deletedAt` may change. For `isCustom = 1`: `id`, `isCustom`, `createdAt` are frozen; `name`, `nameNormalized`, `category`, `defaultMetric`, `equipment`, `defaultRestSec` may change via edit.
2. **Edit semantics:** Editing a custom exercise writes a new `updatedAt`, recomputes `nameNormalized` (BR-001), and does NOT touch any referencing `CompletedSet` rows — they reference by `exerciseId`, so no cascade.
3. **Delete semantics:** Soft-delete sets `deletedAt`; nothing else is touched. Restoring clears `deletedAt` and rewrites `updatedAt`.
4. **ID policy:** Custom IDs are UUID v4 (lowercase, hyphenated) generated client-side. Built-in IDs are exactly the slug in the seed file — never mutate them across app versions, because any existing CompletedSet whose `exerciseId` points at one would orphan otherwise.
5. **Additive-only:** Across versions of this contract, columns may be added nullable; never renamed or removed. (Mirrors #4's rule; SC-foundation@1.0.0 owns the same wording for the base table.)
6. **Derivation rules:** None — this contract stores no derived counters. (Streaks, PRs, last-used, volume are all downstream; they query `Exercise` but never write to it.)

## 4. Business Rules

- **BR-001 (name normalization):** Given a display name `s`, the canonical key is `lowercase(trim(collapseWhitespace(s)))` — lowercased, leading/trailing whitespace removed, interior runs of whitespace collapsed to a single space. `nameNormalized` is computed at write time only; never re-derived on read. (Source: #3, #15.)
- **BR-002 (built-in read-only):** Any write path that would mutate `name`, `category`, `defaultMetric`, `equipment`, or `defaultRestSec` on a row with `isCustom = 0` must be rejected at the DAO layer (a no-op with an error, not a silent pass). (Source: #20.)
- **BR-003 (search matching):** Picker search matches with case-insensitive **substring** against `nameNormalized` (after BR-001 on the query). No fuzzy edit distance, no prefix-only — substring keeps "db bench" and "incline bench" findable. Match must include tombstoned rows only in the "admin/restore" surface (§5); **not** in the picker.
- **BR-004 (category filter composition):** A non-null category filter ANDs with the search query — it never replaces it. Clearing the query returns the picker to `idle` browse, not to a filtered list.
- **BR-005 (create-custom dedupe):** When the user confirms create-custom with display name `s`: (a) if a non-tombstoned row already exists with `nameNormalized = normalize(s)`, the picker selects that existing row instead of creating; (b) else if a tombstoned custom row exists with that key, **restore** it (clear `deletedAt`) and select it; (c) else if a tombstoned *built-in* exists with that key, restore it to `builtIn` and select it; (d) else insert a new row with a fresh UUID, `isCustom = 1`, `name = trim(s)` (preserving the user's casing), and `nameNormalized = normalize(s)`. (Source: #3 invariant 3, #20.)
- **BR-006 (built-in identity stability):** The seed file ships with the app. On every launch the seeder performs an idempotent `INSERT OR IGNORE` keyed on slug `id`. Renaming a built-in in future versions is a NEW slug AND a tombstone of the old slug, never a rename of an existing slug. (Source: #20.)
- **BR-007 (import bridge):** CSV import (#30) uses BR-001 to normalize each Hevy `exercise_title`, then BR-003-equivalent exact match on `nameNormalized` against all non-tombstoned rows (built-ins + customs). On match: link `CompletedSet.exerciseId` to that row. On miss: insert custom per BR-005(d) — this runs OUTSIDE the picker, but reuses the DAO path `insertCustom`. (Source: #15, #20.)
- **BR-008 (tombstone restore window):** Restoring any tombstoned row clears `deletedAt` and updates `updatedAt` atomically. There is no expiry — a tombstoned row is restorable forever, backing INV-L3. (Source: #3 invariant 2.)
- **BR-009 (defaultRestSec slot):** `defaultRestSec` is `Int?` in seconds; `NULL` means "no override — fall to the next level in #9's hierarchy." The picker does not default, suggest, or validate this field; it is only editable from the exercise-detail view (#21 surfaces it; this contract only owns the slot). (Source: #9.)
- **BR-010 (empty-library payload):** When any picker-state query returns zero rows (either because the library is empty — a broken seed — or because the current filters match nothing), the picker reaches `noResults` and renders §6 `picker.noMatches` + `picker.createCustom`. There is no separate "library is broken" UI state in v1. (Source: #14.)

## 5. API Contract

**Local-only; streams nothing.** (Per #4 the entity syncs in phase two, but v1 ships with zero network.) Phase-two shape, for the seam record: sync policy for `Exercise` will be field-level last-write-wins keyed on `updatedAt`; deletions via `deletedAt` tombstones; identity by UUID/slug — this section is a precomputed note, not an endpoint.

### Picker modal contract (in-process API)

The picker is presented modally. It is invoked with a parameter bag and resolves with a result enum. Platforms MUST NOT expose the picker's internal query layer; callers may only pass parameters and consume the result.

```
ExercisePicker.show(
    allowCreate: Bool = true,          // false in library-browse contexts that don't want the CTA
    initialQuery: String = "",
    categoryFilter: ExerciseCategory? = nil,   // pre-selects one category; user can clear
    excludeIds: Set<ExerciseID> = []           // excluded from list & search (e.g. routine editor hiding already-added)
) -> PickerResult

enum PickerResult {
    case selected(exerciseId: ExerciseID)             // any non-tombstoned row
    case createdCustom(exerciseId: ExerciseID, name: String)  // fresh row, just inserted
    case cancelled                                     // user dismissed without choosing
}
```

- `allowCreate = false` hides the create-custom CTA even in `noResults`.
- `initialQuery` pre-fills the search field — the picker enters directly in `searching`, never `idle`.
- `categoryFilter` pins the browse/`searching` filter; user-clearable.
- `excludeIds` is ANDed into every query.
- **Callback shape (corresponds to §2b):** emits exactly one `PickerResult` per presentation; on `createdCustom`, the sheet auto-selects and emits in the same handler.

### DAO interface (consumed by picker, #21 surfaces, #30 import)

```
ExerciseDAO {
    func search(query: String, category: ExerciseCategory?, excludeIds: Set<ExerciseID>) -> [Exercise]
       // filters non-tombstoned rows; apply BR-001 to `query`; substring-match per BR-003;
       // sorted: exact normalized-name hit first, then built-ins first, then alphabetical.
    func getById(_ id: ExerciseID) -> Exercise?           // includes tombstoned (for name resolution INV-L3)
    func findByNormalizedName(_ name: String) -> Exercise? // BR-001 applied to input
    func insertCustom(name: String, category: ExerciseCategory, defaultMetric: DefaultMetric,
                      equipment: ExerciseEquipment, defaultRestSec: Int?) throws -> Exercise
       // applies BR-001 + BR-005 dedupe inside one SQLite transaction; returns the existing row
       // in the dedupe branches and the fresh row in branch (d).
    func tombstone(_ id: ExerciseID) throws
    func restore(_ id: ExerciseID) throws
    func listBuiltIns() -> [Exercise]                       // for detail/library surfaces
    func listAllForSync() -> [Exercise]                     // tombstoned included; used by sync later
    func seedBuiltInsIfNeeded(seedURL: URL) throws          // BR-006 idempotent
}
```

`search` and `insertCustom` are the only methods the picker itself calls. The rest exist for #21 (library screen), #22 (money screen), #30 (import).

### "Empty" payload contract

| Context | Inputs | Result payload |
|---|---|---|
| `search` with empty library (no rows at all) | any query, any filter | `[]` |
| `search` with non-empty library but no substring match | e.g. `"zz"` | `[]` |
| `search` where all matches are in `excludeIds` | — | `[]` |
| Picker receives `[]` | any of the above | `noResults` state per §2b + §6 `picker.noMatches` / `picker.createCustom` |

All of these are the same `noResults` state; the payload that drives it is simply an empty array from `search`.

## 6. UI Copy

Every user-facing string referenced by the picker or the library surface, keyed by dot-path ID. Dynamic values use `{placeholder}`.

| Key | String |
|---|---|
| `picker.title` | "Choose exercise" |
| `picker.searchPlaceholder` | "Search exercises" |
| `picker.categoryHeader` | "Browse by category" |
| `picker.noMatches` | "No matches" |
| `picker.noMatchesSubhead` | "Try a different spelling, or add it as a custom exercise." |
| `picker.createCustom` | "Create custom exercise" |
| `picker.createTitle` | "New custom exercise" |
| `picker.createNameLabel` | "Exercise name" |
| `picker.createNamePlaceholder` | "e.g. Hack squat, Smith incline press" |
| `picker.createCategoryLabel` | "Category" |
| `picker.createMetricLabel` | "Default tracking" |
| `picker.createMetric.reps` | "Reps" |
| `picker.createMetric.duration` | "Duration" |
| `picker.createEquipmentLabel` | "Equipment" |
| `picker.createConfirmCTA` | "Add exercise" |
| `picker.createCancelCTA` | "Back" |
| `picker.detail.title` | "Exercise" |
| `picker.detail.categoryLabel` | "Category" |
| `picker.detail.metricLabel` | "Default tracking" |
| `picker.detail.equipmentLabel` | "Equipment" |
| `picker.detail.restSecondsLabel` | "Default rest" |
| `picker.detail.restSecondsUnset` | "Not set" |
| `picker.detail.restSecondsUnit` | "{seconds} s" |
| `picker.detail.editCTA` | "Edit" |
| `picker.detail.deleteCTA` | "Delete exercise" |
| `picker.detail.deleteConfirmTitle` | "Delete "{name}"?" |
| `picker.detail.deleteConfirmBody` | "Your history with this exercise stays. Future pickers won't show it." |
| `picker.detail.deleteConfirmConfirm` | "Delete" |
| `picker.detail.deleteConfirmCancel` | "Cancel" |
| `picker.detail.restoreCTA` | "Restore" |
| `picker.category.chest` | "Chest" |
| `picker.category.back` | "Back" |
| `picker.category.shoulders` | "Shoulders" |
| `picker.category.biceps` | "Biceps" |
| `picker.category.triceps` | "Triceps" |
| `picker.category.forearms` | "Forearms" |
| `picker.category.core` | "Core" |
| `picker.category.quads` | "Quads" |
| `picker.category.hamstrings` | "Hamstrings" |
| `picker.category.glutes` | "Glutes" |
| `picker.category.calves` | "Calves" |
| `picker.category.fullBody` | "Full body" |
| `picker.category.cardio` | "Cardio" |
| `picker.category.other` | "Other" |
| `exercise.libraryTitle` | "Exercise library" |
| `exercise.libraryEmpty` | "No exercises yet." |
| `exercise.libraryEmptyCta` | "Add a custom exercise" |

## 7. Acceptance Criteria

Test vectors cite BRs; all must hold on both platforms.

| # | Setup | Action | Expected | Cites |
|---|---|---|---|---|
| V1 | Library seeded; built-in `"Barbell Bench Press"` present. | `search(query: "barbell bench press", category: nil, excludeIds: [])` | Returns row matching that built-in at top hit. Match is case-insensitive + trim per BR-001. | BR-001, BR-003 |
| V2 | Custom exercise `"Cable Woodchopper"` exists. | `insertCustom(name: "  Cable   Woodchopper  ", ...)` (different spacing/case) | Returns existing row (BR-005(a)); no new row exists. | BR-001, BR-005 |
| V3 | Built-in `"Barbell Curl"` is tombstoned via `tombstone`. | `getById(id)` | Row returned with `deletedAt` set; `name` still resolves to "Barbell Curl". | INV-L2, INV-L3 |
| V4 | No row matches "Tibialis raise". | Picker search "Tibialis raise" → tap `picker.createCustom` → confirm with defaults. | New row inserted; `isCustom = 1`; `id` is a UUID not equal to any built-in slug; callback emits `.createdCustom(id, name)`. | BR-005(d), INV-P4 |
| V5 | Two exercises in library: one `defaultMetric = reps`, one `defaultMetric = duration`. | `search(query: "")` after entering `idle` and tapping any category. | Both rows render; duration row shows duration badge. | §3b |
| V6 | Library is empty (seed file deleted / first launch with empty seed). | `search(query: "press", ...)` | Returns `[]`; picker enters `noResults`; §6 `picker.noMatches` + `picker.createCustom` shown. | BR-010 |
| V7 | Custom `"Kettlebell halo"` tombstoned. | `insertCustom(name: "kettlebell halo", ...)` | Existing row restored per BR-005(b); `deletedAt` cleared; same `id` reused. | BR-005(b), BR-008 |
| V8 | Built-in `"Face Pull"` present, active. | Picker search `"face"` with `categoryFilter = .back`. | Shows only face-pull rows whose category = back; chest rows filtered out even if matching. | BR-004 |
| V9 | Custom exercise created via V4. | `tombstone(id)` then `search("Tibialis raise")` | Returns `[]` (tombstoned rows excluded); picker re-enters `noResults`. | BR-003, BR-008 |
| V10 | Seed re-install (launch #2). | `seedBuiltInsIfNeeded(seedURL:)` | Idempotent: built-in count unchanged; no `updatedAt` mutations on pre-existing rows. | BR-006 |

Edge cases to hold: zero-length search (treated as `idle`, not `noResults`); search consisting only of whitespace (same treatment — BR-001 collapses it to empty); category filter + zero-length query (category browse view, not `noResults`); `excludeIds` containing the ID the user is about to select (filtered BEFORE it can be tapped).

## 8. Rejected Alternatives

- **Hard-delete for customs** → rejected: INV-L3 (name resolution must survive) and #3 invariant 2; tombstones are the only delete.
- **Fuzzy search (edit distance or prefix-only)** → rejected: substring is cheap, matches mental model ("dumb bench" finds "Dumbbell Bench Press"), and test vectors stay exact. Fuzzy belongs to a future search-quality contract, not here.
- **Built-ins hardcoded in Swift/Kotlin code** → rejected: a JSON seed file is reviewable by non-engineers (trainers can PR it) and keeps RN/Flutter ports free of duplicated lists. (Source: #20)
- **`defaultRestSec` on built-ins pre-populated** → rejected: defaults are #9's job; this contract only owns the nullable slot (BR-009).
- **UUID for built-ins** → rejected: a stable slug keeps cross-device installs referring to the same exercise (e.g. when a Hevy import happens on one device and the CSV is re-imported on a fresh install elsewhere). (Source: #20)
- **Search index FTS table in v1** → rejected: estimated v1 catalog is < 500 rows; a LIKE substring match on `nameNormalized` with a regular index is sufficient. FTS would add a migration dependency and a rebuild path for zero measurable gain. (Source: #20)
- **Picker as full-screen push instead of modal sheet** → rejected: #7 resolves that the picker is tier-2 sheet per #17's visual system.

## 9. Downstream Effects

- **Feeds #21** (Routine CRUD + Home): the routine editor uses the picker to add exercises; the Home quick-resume card and routine rows only need `Exercise.id` — they never query this module beyond the DAO.
- **Feeds #22** (Active Workout / money screen): per-set exercise names resolve via `getById`; the `[+]` row in exercise group headers can offer a quick-picker invocation; INV-L3 guarantees historic names render after tombstone.
- **Feeds #26** (PRs + Analytics): PR derivation reads `defaultMetric` to know whether a set's "PR" is weight×reps or duration-based.
- **Feeds #30** (CSV import): BR-007 is the contract bridge — import *must* call `insertCustom` for new names and `search`+exact normalized match for linking. Import never invents its own normalization.
- **Feeds #8** (port): frozen at v1.0.0; the Android port implements from this file exact-version.
