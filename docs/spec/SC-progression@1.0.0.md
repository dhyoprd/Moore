# SC-progression@1.0.0 — Smart Progression Engine

```yaml
contractId: SC-progression
version: 1.0.0
status: frozen
created: 2026-08-11
supersedes: none
supersededBy: none
```

Consumes SC-foundation@1.0.0, SC-workout-logging@1.0.0. Referenced by SC-warmup (t+1) for setClass stamping.

---

## 1. State Machine

None for this contract. The engine is a pure function; all persistence is on existing entities (CompletedSet + WorkoutSession reads, ProgressionScheme writes). The stall counter is durable state, not FSM state.

## 2. Data Schema

The single additive asset: `progression_scheme` (full shape, post-0007 canonical).

```
ProgressionScheme = {
  id TEXT PK, routineId, exerciseId,
  scheme: 'none'|'linear'|'double'|'hold-duration'  default 'none',
  incrementValue REAL?,            // display hint only; engine uses inc(E)
  doubleProgressionMinReps INT?, doubleProgressionMaxReps INT?,  // legacy advisory; v1 locks (8,12)
  warmupEnabled INT, stallCount INT, stallMuted INT,
  nextBannerAt INT default 3, deloadPending INT default 0,
  lastDeloadSessionId TEXT?, stalledWeight REAL?, stalledReps INT?, stalledDurationSec INT?,
  baselineDurationSec INT?, // hold-duration only
  createdAt, updatedAt, deletedAt
}
```

## 3. Business Rules

- BR-001 — The engine NEVER adds or removes blueprint rows and NEVER mutates PlannedSet; rows only ever get their materialized `plannedX` values stamped at session start.
- BR-002 — Scheme attaches per (routineId, exerciseId) pair; default `none`. No global default scheme.
- BR-003 — Engine only fires from session 2 of a pair onward. First-session materialization = blueprint values verbatim.
- BR-004 — History lookup: completed sessions containing ≥1 non-dropped CompletedSet with this exerciseId, newest first, same-routine preferred, capped at 5.
- BR-005 — Reference-set weight W = actualWeight of reference session's last non-dropped set for the exercise.
- BR-006 — Clean session predicate C(S,E) = zero `failed` sets AND every work set actualReps ≥ plannedReps (reps metric) OR actualDurationSec ≥ plannedDurationSec (duration metric). Dropped never counts.
- BR-007 — Failed-set target donation: F = MAX(actualReps) across reference-session failed sets (−∞ if none); use min(F, P) when not clean.
- BR-008 — Scheme math on clean session: `none` = last actuals verbatim; `linear` = round125(W + inc(E)); `double` = if P≥12 → round125(W+inc(E)) else P+1 capped at 12; `hold-duration` = min(P+5, baselineDurationSec+60).
- BR-009 — inc(E): 5.0 kg if `Exercise.category` lowercased contains any of {legs, quads, hamstrings, glutes, calves}; else 2.5 kg. Ambiguous/unset categories upper-biased to 2.5 kg.
- BR-010 — round125(x): nearest 1.25 half-up floored at 0. round25(x): nearest 2.5 half-up. Deloads only use round25.
- BR-011 — Bodyweight (W=NULL): `linear` degenerates to `none`; `double` progresses reps; `hold-duration` unaffected.
- BR-012 — Stall counter: on a finished session containing ≥1 performed (non-dropped) set for E — (a) clean(S,E) → stallCount=0; (b) W ≠ previous-performed session's W → stallCount=0; (c) ≥1 failed AND maxActualReps < target → stallCount+=1; (d) else unchanged. Sessions where E wasn't performed don't touch the counter.
- BR-013 — Banner fires exactly once per materialization when stallCount == nextBannerAt. Copy: "Looks stalled on <name> — <n> sessions short of target. [Deload −10%] [Hold] [Ignore]". Deload renders only when stalledWeight exists.
- BR-014 — Deload: sets deloadPending; next materialization suggests round25(stalledWeight × 0.90) at stalled reps/duration for exactly one session; the subsequent materialization unconditionally re-enters at stalledWeight at stalled targets; deload session's own outcome ignored. stallCount resets.
- BR-015 — Hold: nextBannerAt = stallCount + 2 (re-asks at 5,7,9...poisson if still stalling).
- BR-016 — Ignore: stallMuted=1; no further banners until the scheme is manually edited.
- BR-017 — Editing a pair's scheme or blueprint weight from the routine editor resets stallCount, stallMuted, nextBannerAt=3.
- BR-018 — UI surfaces: inline plannedX text only on Active Workout; one-line "Next:" line on routine preview; non-modal tap-to-apply banner; NEVER modal, NEVER blocks ✓, can be overridden by bottom-sheet edit (which silently resets the chain).
- BR-019 — RPE / velocity / fatigue / periodization / percentage-of-1RM / ML are expressly out of scope for v1.
- BR-020 — suggestions at materialization; PR interplay separate by construction (§7 of source).

## 4. API Contract

```
enum Scheme { case none, linear, double, holdDuration }
struct Suggestion { let weight: Double?; let reps: Int?; let durationSec: Int?; let modified: [String] }
struct StallState { let shouldBanner: Bool; let copy: String?; let actions: [StallAction] }
enum StallAction { case deload, hold, ignore }

protocol ProgressionEngine {
    static func suggest(routineId: String, exerciseId: String) -> Suggestion
    static func onSessionFinished(sessionId: String) -> [PairKey: StallState]
    static func applyStallChoice(_ choice: StallAction, routineId: String, exerciseId: String) -> Void
}
```

## 5. UI Copy

| Key | String |
|---|---|
| `progression.nextLine` | "Next: {name} {weight}×{reps}" |
| `progression.banner.stall` | "Looks stalled on {name} — {n} sessions short of target." |
| `progression.banner.deloadCta` | "Deload −10%" |
| `progression.banner.holdCta` | "Hold" |
| `progression.banner.ignoreCta` | "Ignore" |

## 6. Acceptance Criteria (test vectors)

| ID | Scenario | Expected |
|---|---|---|
| V1 | OHP linear, last session clean @ 50kg×10 → next | 52.5kg×10 |
| V2 | Squat linear, last session clean @ 100kg×5 → next (category contains 'legs') | 105kg×5 |
| V3 | Ambiguous category linear clean @ 30kg → next | 32.5kg (upper-biased) |
| V4 | Double ceiling: all sets at 12 reps clean → next | W+inc, reps=8 |
| V5 | Double middle: 10 reps clean → next | reps=11 |
| V6 | Hold-duration: 60s clean, baseline 60 → first tick | 65s |
| V7 | Hold-duration cap: baseline 60, at 120s clean → next | 120s (capped at baseline+60) |
| V8 | First session on pair | Blueprint values verbatim |
| V9 | 6 session history — engine reads newest 5 only | latest reference is session-5-back (6th ignored) |
| V10 | Failed session, failed sets [4, 6, 5] with target 8 → suggestion | weight held, target=min(6,8)=6 |
| V11 | Stall: 3 consecutive unclean sessions same weight | stallCount==3, banner surfaces once |
| V12 | Stall reset on weight change | 2 stalls, manual bump, next session unclean → stallCount==1 (not 3), no banner |
| V13 | Deload flow: accept → next session 0.9×W round25 | exactly one session at −10%, then re-entry at stalled weight |
| V14 | Hold flow: hold at 3 stalls → banner re-asks at stall 5 | nextBannerAt=5 |
| V15 | Ignore flow: ignore at 3 stalls → no further banners even at stall 6 | stallMuted=1 |
| V16 | Edit blueprint weight → chain resets | stallCount=0, stallMuted=0, nextBannerAt=3 |

## 7. Rejected alternatives

- RPE/RIR autoregulation (adds UI taps, violates set contract).
- Percentage-of-1RM schemes (requires a logged 1RM users may never have).
- Periodization/waves (v1 is session-local).
- ML-driven suggestions (violates "rules-based, mechanically portable" charter).
- Warm-up generation inside this engine (separated to SC-warmup@1.0.0).

## 8. Downstream effects

- **SC-warmup (`t+1`)**: consumes Materialized working weight to derive ramp; `warmupEnabled` gate lives on `ProgressionScheme`.
- **#7 / Active Workout**: planned values read via `plannedX` per BR-018 (no new surfaces).
- **#27 (Analytics)**: reads `stallCount/time-series` to render stall events per exercise (implementation detail there).
- **#8 / Port parity**: every function is pure and closed-form; Java/Swift implementations must match outputs byte-for-byte per contract.