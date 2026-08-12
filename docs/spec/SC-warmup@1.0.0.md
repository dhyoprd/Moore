# SC-warmup@1.0.0 — Warm-up Ramp Auto-Generation

```yaml
contractId: SC-warmup
version: 1.0.0
status: frozen
created: 2026-08-12
supersedes: none
supersededBy: none
```

Consumes SC-foundation@1.0.0 (`setClass`, `warmupEnabled` columns), SC-workout-logging@1.0.0 (materialization seam, `SetClass`, 1-tap accept), SC-progression@1.0.0 (the stamped working weight this contract consumes; BR-001's no-blueprint-mutation rule it must obey), SC-plate-calculator@1.0.0 (BR-001 inventory/bar, BR-003 nearestDown). Source: #16 resolution comment, delivered under #25.

---

## 1. State Machine

None for this contract. Ramp derivation is a one-shot pure function executed at session materialization time — after `suggest()` has stamped work-set `plannedX` values, before the session row set is presented. Generated rows then live entirely under SC-workout-logging@1.0.0's per-set FSM (`planned → completed | failed | dropped`) with no warm-up-specific states.

## 2. Data Schema

**Zero new columns.** All three #16 model additions already exist:

```
PlannedSet.setClass            'warmup'|'work', nullable   — shipped in 0002
CompletedSet.setClass          'warmup'|'work', nullable   — shipped in 0002
ProgressionScheme.warmupEnabled  INTEGER 0|1 default 0     — shipped in 0002, canonical post-0007
```

NULL `setClass` coalesces to `'work'` on read (SC-foundation INV-6). `warmupEnabled` attaches per `(routineId, exerciseId)` pair — the same edit surface as scheme selection (SC-progression BR-002).

Migration `0008_warmup_per_exercise_toggle.sql` is a **scaffold no-op**: registers SC-warmup's presence in the migration chain, re-asserts the `warmupEnabled` column exists (guard, never alters), and carries the post-0008 **expected shape** (documented) below for both verifiers and the Android port (#31):

```
WarmupRow (derived, not a table) = {
  exerciseId, sortOrder: int,            -- inserted before that exercise's first work row
  plannedWeight: real, plannedReps: int, -- per §3 ramp table, nearestDown-rounded
  actualWeight/actualReps/actualDuration: NULL,
  status: 'planned', setClass: 'warmup', completedAt: NULL
}
```

## 3. Business Rules

**Derive (BR-001..BR-007)** — pure function, session-materialization-time, per reps-metric exercise:

- **BR-001 (source of W):** W = `MAX(plannedWeight)` over that exercise's `setClass='work'` (incl. NULL-setClass) rows **in the materialized session being built** — post-suggest, post-deload, immune to per-row drift under scheme `none`. No scheme-specific warm-up code exists anywhere.
- **BR-002 (gate):** generate only when the exercise metric is `reps` AND `warmupEnabled=1` for the pair AND W is non-null AND `W > bar` (`bar` = active inventory bar weight per SC-plate-calculator BR-001). Otherwise zero rows.
- **BR-003 (rung 1, always):** `bar × 10`.
- **BR-004 (two-rung path, `bar < W < 5·bar`):** 50%·W ×5, then 75%·W ×3.
- **BR-005 (three-rung path, `W ≥ 5·bar`):** 40%·W ×5, 65%·W ×3, 85%·W ×2. The 5·bar threshold is exactly where the two-rung 75%→100% jump exceeds ~25 kg; unit-free, zero configuration.
- **BR-006 (rounding):** every percentage target rounds **nearestDown** against the active (user-edited) plate inventory per SC-plate-calculator BR-003 — largest loadable weight ≤ target, never overshoot, computed via the calculator's greedy per-side walk (NOT naive stepping).
- **BR-007 (cleanup, applied in order, after rounding):** (1) a rung rounding to ≤ bar is dropped; (2) if the two-rung path's 50% rung dropped under (1), the whole ramp collapses to `bar×10` only; (3) rungs must be strictly increasing by rounded weight — equal rungs are dropped. The three-rung path has no full-collapse rule: unreachable percentage rungs drop individually, `bar×10` always remains.

**Write (BR-008..BR-010)**:

- **BR-008 (materialization-time write):** rows are written as `completed_set` with `setClass='warmup'`, `plannedX` set, `actualX` NULL, `status='planned'`, inserted **before** that exercise's first work row in ascending load order, with `sortOrder` renumbered contiguously (SC-foundation BR-005) across the whole session — same transaction as the work-row copy.
- **BR-009 (snapshot immutability):** written once, never regenerated. Mid-session work-weight edits never touch the ramp; re-opening a session re-renders stored rows, never recomputes. History renders the same ramp forever (#3 INV-5).
- **BR-010 (toggle default):** `warmupEnabled` defaults 0 (OFF). Generation adds mandatory terminal-state gestures, so opt-in is the only zero-surprise default. The routine-editor row edit sheet surfaces the per-pair toggle (UI ticket); blueprints never carry generated rows.

**Exclusions (BR-011..BR-015)** — every progression/PR/volume/clean rule reads `setClass='work'` (or NULL) rows only:

- **BR-011 (stall detection):** the failed-set scan, W-change chain-break, and stallCounter (SC-progression BR-012) consider work-class rows only. A failed warm-up can neither trip nor reset a stall chain.
- **BR-012 (clean session):** `clean(S, E)` (SC-progression BR-006) filters `setClass IS NULL OR setClass='work'` before evaluating.
- **BR-013 (PR derivation):** all four PR types (`max_1rm`, `max_volume`, `max_reps`, `max_duration`) ignore warm-up rows regardless of values. A bar×10 never writes `max_reps`.
- **BR-014 (session volume):** tonnage aggregates exclude warm-up rows. Rationale (#16 §5.4): volume feeds cross-session comparisons; toggling `warmupEnabled` mid-history would inject artifactual jumps indistinguishable from progression. This **supersedes SC-foundation@1.0.0 INV-6/BR-006's "included in volume"** line, which was written pre-#16-resolution; #16's overrule is canonical.
- **BR-015 (mixed-history reference rule):** when a pre-#25 session is consumed as a progression reference (SC-progression BR-004/BR-005), null-setClass rows read as work rows only if the exercise has **no** `'warmup'`-tagged row in that same session; if any warm-up row exists, ambiguous unclassified rows are dropped from work-class reads. New writes are always classified, so ambiguity never forms post-#25.

**UI (BR-016..BR-018)** — rendering contract, implemented post-integration:

- **BR-016:** warm-up rows render inside their exercise group **before** the work rows, ascending load order, grayed planned-value styling + `WU` chip; work rows stay full-contrast.
- **BR-017:** ✓ accepts planned verbatim in 1 tap (SC-workout-logging's per-set invariant holds for warm-up rows unchanged); swipe-left fail/drop identical; sheet edit available like any row.
- **BR-018:** warm-up rows count toward session completion — they must reach a terminal state for Finish to arm; drop is the cheap mid-session opt-out. Failed warm-ups record actual reps per SC-workout-logging but are filtered by BR-011..BR-014.

## 4. API Contract

```swift
public struct WarmupRow: Equatable, Codable, Sendable {
    public var weight: Double   // absolute, post-nearestDown
    public var reps: Int
}

public enum WarmupRamp {
    /// #16 §2 as a pure function. Empty array ⇔ BR-002 gate fails.
    static func derive(workingWeight: Double?, barWeight: Double,
                       plateInventory: [Double]) -> [WarmupRow]

    /// SC-plate-calculator BR-003 mirror (its code lands in the integration layer;
    /// duplicated here so MooreWarmup has no module dependency and the algorithm
    /// stays byte-comparable for the Android port).
    public static func nearestDown(_ target: Double, barWeight: Double,
                                   plateInventory: [Double]) -> Double?
}

public final class WarmupDAO {
    /// Reads ProgressionScheme.warmupEnabled for a pair without auto-creating a row
    /// (absent row ⇔ default 0). Returns false when routineId is nil (ad-hoc session).
    public func warmupEnabled(routineId: String?, exerciseId: String) throws -> Bool
}

public enum WarmupMaterialize {
    /// Post-work-copy pass, inside the same transaction. Fails soft per pair
    /// (that pair gets no ramp; other pairs still materialize). Never throws
    /// unless the enclosing write fails.
    public static func apply(db: Database, sessionId: String, routineId: String?,
                             barWeight: Double, plateInventory: [Double]) throws
}
```

## 5. UI Copy

| Key | String |
|---|---|
| `warmup.chip` | `WU` |
| `warmup.editor.toggle` | "Auto warm-ups" |
| `warmup.editor.toggleSub` | "Adds a weight-matched ramp at session start. Warm-ups never count toward PRs, volume, or stall detection." |

## 6. Acceptance Criteria (test vectors)

Fixture files under `Tests/MooreWarmupTests/Fixtures/`; Node verifier `VerifyWarmup.mjs` runs them against in-memory SQLite (migrations 0001–0003, 0005–0008). kg inventory `[25,20,15,10,5,2.5,1.25]` doubles per side, bar 20, unless a fixture states otherwise. Cites BR IDs per template §7.

| ID | Scenario (rule) | Expected |
|---|---|---|
| V1 | Percentage table, 7 bodies × both paths: W=30/41.25/50/82.5/99 two-rung, W=100/120 three-rung; W=100 lb w/ lb inventory (BR-003..BR-007) | Rounded ramps match fixture `expect` exactly |
| V2 | `warmupEnabled=0` (default) — BR-002/BR-010 | 0 warm-up rows materialize |
| V3 | Enabled, W=82.5 kg (two-rung with drop): 50%=41.25 loadable; 75%=61.875→60 (BR-004/BR-006/BR-007.3) | rows `[20×10, 41.25×5, 60×3]` `setClass='warmup'` before 3 work rows @82.5×5; session total 6 |
| V4 | Enabled, W=120 kg (three-rung): 48→45, 78→77.5, 102→100 (BR-005/BR-006) | `[20×10, 45×5, 77.5×3, 100×2]` + work @120×5 |
| V5 | W=25 kg: 50%=12.5 ≤ bar → collapse (BR-007.2) | `[20×10]` only |
| V6 | W ≤ bar (W=20; and W=null bodyweight) — BR-002/BR-008 | 0 warm-up rows; bodyweight reps exercise with NULL weights also 0 |
| V7 | Rows written with `setClass='warmup'` then FSM transitions apply unchanged: ✓ 1-tap copies planned→actual; drop terminal (BR-008 materialization shape; BR-017/BR-018 behavior via SC-workout-logging) | post-write row shape exact; accept/drop succeed |
| V8 | PR safety: warm-up actuals at values that would beat every PR kind (e.g. bar×10, and a 5-rep ramp rung vs a 3-rep `max_reps` PR) — BR-013 | `personal_record` untouched (0 new rows) |
| V9 | Volume: `SUM(actualWeight·actualReps)` over completed sets, work-only filter vs all rows (BR-014) | work-only 4125.0 (82.5×5×... see fixture); all-rows 2475 higher — prove exclusion delta |
| V10 | Stall immunity: warm-up fail + all work clean → chain untouched; also 3 consecutive warm-up-fail sessions (BR-011) | no `stallCount` increment, no banner either path |
| V11 | Clean predicate: session with ONLY warm-up failures is still clean (BR-012); immutability: caller-side double-apply guard leaves stored rows untouched (BR-009) | `clean=true`; second `apply` adds 0 rows |
| V12 | Interleaving/renumber: two exercises, only one enabled — warm-up block precedes that exercise's first work row and `sortOrder` stays contiguous 0..n session-wide (BR-008, SC-foundation BR-005) | exact ordered (exerciseId, setClass, weight) sequence |

## 7. Rejected alternatives

- **Manual blueprint warm-up rows as the mechanism** → rejected (#16): stales on every engine bump; is the pain this ticket kills.
- **Engine writes warm-up rows into the routine blueprint** → rejected: violates SC-progression BR-001 outright. Ramps are session rows only.
- **Ephemeral re-derivation on every render, never persisted** → rejected: breaks the immutable session snapshot (History would render rows never logged).
- **Include warm-ups in session volume** → rejected (#16 §5.4): cross-session comparability beats accounting completeness; tagged rows keep an "include warm-ups" analytics toggle derivable later.
- **Fixed absolute rungs (−20 kg / −10 kg)** → rejected: doesn't scale across lifts or units; percentage + nearestDown reuses one frozen rounding contract.
- **User-configurable rung percentages/reps/counts** → rejected: speculative configuration surface; one fixed table plus an on/off toggle is v1.
- **Shorter rest timer after warm-ups** → rejected for v1 scope: rest-duration dispatch already resolves per set (#9); a warm-up rest preset is a separate concern.
- **Default `warmupEnabled = true`** → rejected: generation imposes terminal-state gestures; never silently add taps to an existing flow.

## 8. Downstream effects

- **#26 (PRs, parallel):** PR derivation must filter `setClass IS NULL OR setClass='work'` per BR-013 (+ BR-015 on legacy reads).
- **#7 / Active Workout UI (post-integration):** WU chip, grayed rows, warm-up-first ordering per BR-016/BR-017; routine-editor toggle per BR-010.
- **#27 (Analytics):** tonnage queries filter warm-ups per BR-014; the tag makes a later opt-in inclusion trivially derivable.
- **#31 (Android port):** `derive`/`nearestDown` are closed-form and must match outputs byte-for-byte; `nearestDown` intentionally duplicated from the plate calculator so neither module crosses boundaries.
