# Spec Contract Template — the single source of truth format

**Status: frozen (template itself, v1).** Every feature of the Moore strength tracker is specified as a *contract* written in this exact shape. The contract is the only artifact both platforms (SwiftUI iOS-first, Kotlin Android port) are allowed to implement against. If a behavior is not in a contract, it does not exist.

A contract is **platform-agnostic**: no Swift, no Kotlin, no SwiftUI/Compose, no CoreData/Room/SQLite dialect. States, fields, math, and semantics only. Mechanical translation rules live in the port plan (#8), never in a contract.

---

## 0. Contract anatomy — section order and purpose

A contract file has exactly these sections, in this order. Sections marked ◆ are mandatory; ◇ sections may be the literal line `None for this contract.` — never delete a section, never reorder.

| # | Section | Purpose |
|---|---|---|
| ◆ 1 | Front-matter | Identity, versioning, status, provenance |
| ◇ 2 | State Machine | Named states, transitions, invariants |
| ◇ 3 | Data Schema | Entities, field contracts, invariants, derivation rules |
| ◆ 4 | Business Rules | Numbered, testable, source-cited rules |
| ◇ 5 | API Contract | Sync/streaming semantics + endpoint contracts (phase two) |
| ◆ 6 | UI Copy | Every user-facing string, keyed by ID |
| ◆ 7 | Acceptance Criteria | Test vectors + edge cases that close the contract |
| ◆ 8 | Rejected Alternatives | What was considered and killed, and why |
| ◆ 9 | Downstream Effects | What this unblocks / feeds |

---

## 1. Front-matter ◆

YAML block at the very top of the file. This is how contracts are versioned across platforms without drift — the Android port consumes the version field, and #8 freezes by version number.

```yaml
---
contractId: "SC-<feature-slug>"      # stable kebab-case ID, e.g. SC-plate-calculator. Never reused.
version: "1.0.0"                     # semver: MAJOR = behavior change needing re-port; MINOR = additive fields/copy; PATCH = wording/clarity
status: draft | frozen | superseded  # draft=editable; frozen=port-ready, needs a ticket to change; superseded=dead
date: "YYYY-MM-DD"                   # date of last status change
source: "#N"                         # ticket that resolved this contract
supersedes: "SC-... @x.y.z" | null   # what this contract kills
supersededBy: "SC-..." | null        # set automatically when killed; a superseded contract is never edited again
---
```

**Precision bar:** a frozen contract can only change via a new ticket that bumps `version` and states the diff in its resolution. iOS and Android never implement the same contractId at different MAJOR versions — that is the definition of port drift.

## 2. State Machine ◇

Style reference: #2. Every user-reachable state gets a row; transient UI is explicitly named as such.

**States table** — `State | Meaning | Entered by | Exits`:

| State | Meaning | Entered by | Exits |
|---|---|---|---|
| `idle` | One-line definition | The exact user action or event that lands here | Every way out, with the arrow target named |

**Transition matrix** — for machines with >3 states, the full from×to grid with the triggering event in each cell; `-` = illegal:

| from \ to | stateB | stateC |
|---|---|---|
| stateA | event-name | `-` |

**Invariants** — numbered statements that hold in *every* state, e.g. *"INV-2: no `rest` overlay exists while zero sets are terminal."* Invariants are what platform ports write property tests against.

**Precision bar:** "supersets skip the auto-rest" (from #2) — the transition is named by *event*, not by vibes.

## 3. Data Schema ◇

Style reference: #3. Three parts, in order.

**(a) Entity table** — `| Entity | Role | Key relationships |`, one row per entity, relationships written as `fieldId → OtherEntity`.

**(b) Field contracts** in the exact notation from #3 — `?` = optional, `|` = enum literal, trailing fields are not reorderable prose:

```
EntityName = { id, foreignId, fieldA?, kind: litA|litB, updatedAt }
```

Precision bar from #3: `CompletedSet = { id, sessionId, exerciseId, plannedWeight?, plannedReps?, …, status: planned|completed|failed|dropped, … }` — every field named, optionality named, enums named. No "etc.", no "…and other obvious fields".

**(c) Invariants + derivation rules** — numbered list covering: immutability (which fields never change post-write), edit/delete semantics and any recalc cascade, ID/tombstone policy (`deletedAt`, never hard-remove), and the additive-only rule (never rename/delete fields across versions; only add nullable ones). Derivation/PR rules state the exact formula and its filter set, e.g. *"`max_1rm` ← Epley `weight × (1 + reps/30)` over `status = completed` sets only; written transactionally at completion; re-derived on edit/delete."*

## 4. Business Rules ◆

One numbered rule per behavior, each with a stable ID and its source ticket. Rules are the unit that tests cite.

```
BR-001: <exact statement of the rule, with formula/threshold written out>. (Source: #N)
```

**Precision bar:** `BR-001: Epley 1RM = weight × (1 + reps/30), computed over reps-sets in status=completed only; failed sets never write PRs. (Source: #3)` — the formula, the filter set, the negative case, the provenance, all in one line. A rule you cannot write a table-driven test against is not finished.

## 5. API Contract ◇

Local-first: v1 ships with zero network. This section is the *pre-computed* sync seam (per #4) so cloud bolt-on needs no rewrite. If the feature is purely local, state `Local-only; streams nothing.` and stop.

If it syncs, specify in order:

- **Streams:** exactly which entities/fields leave the device (and which never will).
- **Sync semantics:** conflict policy per entity — the default is **last-write-wins at field granularity**, keyed on `updatedAt`; deletions are **tombstones** (`deletedAt`), never row removal; identity is UUID, so no ID-mapping layer ever exists.
- **Endpoint contracts**, one per endpoint:

```
POST /v1/<resource>
Request:  { <fields, types, required/optional> }
Response: 200 { <fields> } | 422 { errors: [{ field, code }] }
Errors:   401 unauthenticated · 409 stale updatedAt (server row newer → client must merge)
```

**Precision bar:** the conflict policy names the granularity (field, not row) and the key (`updatedAt`), and tombstones are named as the delete mechanism — "syncs eventually" is banned vocabulary.

## 6. UI Copy ◆

Every user-facing string, keyed by dot-path ID, in one table. Both platforms ship identical copy — the Android port substitutes nothing. English-first; the key (not the string) is what code references, so localization later changes only this table's value column.

```
| Key | String |
|---|---|
| plateCalculator.title | "Plates" |
```

Named `feature.element[.variant]` — e.g. `activeWorkout.finishCTA = "Finish Workout"` (#2), `plateCalculator.errorAboveMax = "Over max load — add plates"`. Dynamic values use `{placeholder}` tokens. If a screen shows text, the text is here or the contract is incomplete.

## 7. Acceptance Criteria ◆

Test vectors as tables of input → output covering the happy path, every rounding/boundary rule, and every error state. These close the contract: when all vectors pass on both platforms, the feature is done. Property tests cite section-2 invariants by ID.

## 8. Rejected Alternatives ◆

Bullet list: `— **<alternative>** → rejected: <one-line reason>.` Style reference: #2/#3. This section is load-bearing — it stops future agents from re-litigating settled design space.

## 9. Downstream Effects ◆

Bullet list of `Unblocks #N` / `Feeds #N` / `Surfaced #N` with one-line why, so the map's frontier stays current.

---

## How agents must read this

1. **Before writing any Swift/Kotlin for feature X, read contract X (the file, current frozen version).** Not the ticket, not the map — the contract.
2. **Only `status: frozen` contracts may be implemented.** Drafts are conversation, not instruction.
3. **If behavior you need isn't in the contract, STOP and open a ticket — never invent behavior in code.** An agent that finds a gap in a frozen contract treats it exactly like a compiler error: halt, surface, wait for the amended contract.
4. **Platform code cites the contract.** Every feature module header carries `contractId @version`. PRs whose behavior diverges from the cited version are rejected without review.
5. **Copy is never hardcoded** — code references UI-copy keys; the string table in section 6 is the build-time source.
6. **When a contract supersedes another, re-read before touching legacy code** — `supersededBy` chains are the migration path.
7. **Test names cite rule IDs** (`BR-001`, `INV-2`, test-vector row numbers). A failing `BR-001` test is a spec violation, not an implementation opinion.

---

# Worked example — fully filled contract

---

# Contract: Plate Calculator

```yaml
---
contractId: "SC-plate-calculator"
version: "1.0.0"
status: frozen
date: "2026-07-30"
source: "#6"
supersedes: null
supersededBy: null
---
```

A pure mechanical function: from target weight, bar weight, inventory, and unit, produce the plates per side. Zero persistence, zero network, zero state. This is the smallest possible complete contract — it exists to set the precision floor for every larger one.

## 2. State Machine

None for this contract. The plate calculator is a pure function plus a transient result view: inputs in → one `PlateSet` out. Explicitly **no states**: nothing persists, nothing locks, the result recomputes on every input change and is never stored.

## 3. Data Schema

No persisted entities. Derived types only (exist for the duration of one computation, never stored):

```
PlateSet     = { perSide: [PlateCount], perSideLoad: Mass, achievable: Mass, remainder: Mass }
PlateCount   = { plate: Mass, count: int }          // count ≥ 1, sorted plate DESC
PlateInventory = { available: [PlateCount] }        // finite realistic inventory: count = pairs owned
RoundingMode = { nearestDown | nearestUp | exactOnly }
Mass         = number ≥ 0, in the active Unit
Unit         = { lb | kg }
```

**Invariants**

1. **INV-1:** `PlateSet` is always feasible to physically stage — every plate named exists in `PlateInventory` with sufficient count (plates consumed on one side are consumed symmetrically; `count` in output is *per side*, so inventory needs `2 × count`).
2. **INV-2:** Bar load is symmetric by construction — the output names one side only; the UI renders both.
3. **INV-3:** Total bar load = `barWeight + 2 × perSideLoad` is preserved by display. If target is not exactly achievable, the bar visibly shows `achievable/requested`, never silently the requested number.

**Derivation rules**

- `perSideTarget = (target − barWeight) / 2` in the **target's unit**; conversion happens before any arithmetic, never mid-greedy.
- Greedy largest-first: walk `available` plates DESC, take `min(floor(remaining / plate), inventoryCount)` repeatedly until nothing more fits.
- Rounding applies to `perSideTarget` **before** the greedy walk (BR-003), never per-plate.

## 4. Business Rules

- **BR-001 (standard sets):** lb inventory = {45×6, 35×2, 25×2, 10×4, 5×2, 2.5×2} pairs, bar = 45.0 lb; kg inventory = {25×4, 20×2, 15×2, 10×2, 5×2, 2.5×2, 1.25×2} pairs, bar = 20.0 kg. Users may edit counts and bar weight per gym; the edited inventory is the contract's input, never hardcoded. (Source: #6)
- **BR-002 (ordered validation):** evaluate in order and show the *first* failing state: (1) `target < bar` → below-bar error; (2) `(target − bar)` not representable even with smallest available plate → `exactOnly` yields unachievable state, else apply BR-003; (3) target above max stackable → above-max error. (Source: #6)
- **BR-003 (rounding):** `nearestDown` rounds `perSideTarget` to the largest value achievable ≥ 0 from inventory (never overshoot — safety rule: undershoot is always preferred); `nearestUp` rounds to smallest achievable value ≥ target and **must** annotate `units.over`; `exactOnly` produces the unachievable state with `remainder` shown. Default = `nearestDown`. (Source: #6)
- **BR-004 (unavailable-plate fallback):** inventory is finite; when the greedy walk exhausts a plate size it falls through to smaller plates. If the result under-loads vs target, the contract returns an annotated `PlateSet` (`remainder > 0`, `units.under`) — never silently, never an error. (Source: #6)
- **BR-005 (unit conversion):** display-unit change converts all shown values (`mass = kg × 2.20462`, inverse `lb ÷ 2.20462`) then re-runs validation+greedy in the **target unit** (input given in lb resolves against lb inventory). Display rounds to the smallest denomination of the display unit's set (2.5 lb / 1.25 kg); internal values keep full precision. (Source: #6)
- **BR-006 (impossible requests):** below-bar and above-max are explicit UI states with the exact string from §6 — never clamped silently, never crash. (Source: #6)

## 5. API Contract

Local-only; streams nothing. Per #4 the feature has no entity (nothing persisted), so it has no sync surface. If gym inventories are later promoted to a persisted `GymProfile` entity, that entity syncs under the default field-level LWW policy and this section is amended by ticket.

## 6. UI Copy

| Key | String |
|---|---|
| `plateCalculator.title` | "Plates" |
| `plateCalculator.targetLabel` | "Target weight" |
| `plateCalculator.barLabel` | "Bar: {barWeight} {unit}" |
| `plateCalculator.perSideHeader` | "Per side" |
| `plateCalculator.plateLine` | "{count} × {plate} {unit}" |
| `plateCalculator.totalLine` | "Bar total: {achievable} {unit}" |
| `plateCalculator.units.under` | "{remainder} {unit} under target — closest load with these plates" |
| `plateCalculator.units.over` | "{remainder} {unit} over target — rounded up" |
| `plateCalculator.errorBelowBar` | "Target is under bar weight" |
| `plateCalculator.errorAboveMax` | "Over max load — add plates" |
| `plateCalculator.unableToLoad` | "Can't build {target} {unit} with available plates" |

## 7. Acceptance Criteria

Test vectors (lb inventory + 45 lb bar per BR-001, `nearestDown` default):

| # | target | bar | unit | Expected `perSide` | Expected `achievable` | State |
|---|---|---|---|---|---|---|
| V1 | 225 | 45 | lb | `[{45, 2}]` | 225.0 | exact |
| V2 | 135 | 45 | lb | `[{45, 1}]` | 135.0 | exact |
| V3 | 100 | 45 | lb | `[{25, 1}, {2.5, 1}]` | 100.0 | exact |
| V4 | 227.5 | 45 | lb | `[{45, 2}]` | 225.0 | `units.under` remainder = 2.5 (nearestDown never overshoots) |
| V5 | 45 | 45 | lb | `[]` | 45.0 | exact (empty bar is legal) |
| V6 | 40 | 45 | lb | — | — | `errorBelowBar` |
| V7 | 1500 | 45 | lb | — | — | `errorAboveMax` |
| V8 | 60 | 20 | kg | `[{20, 1}]` | 60.0 | exact (kg set, 20 kg bar) |
| V9 | 102.5 | 20 | kg | greedy DESC walk per side against 41.25 target: take 25 (16.25 left), 15 (1.25 left), 1.25 (0 left) → `[{25, 1}, {15, 1}, {1.25, 1}]` | 102.5 | exact |
| V10 | 100 kg entered, displayed / resolved in lb | 45 | kg→lb input | target converts to 220.462 lb, unrepresentable in lb set → per-side 87.731 rounds nearestDown to 87.5 = `[{35, 1}, {25, 1}, {10, 2}, {5, 1}, {2.5, 1}]` | loads to 220.0 lb, shown as 99.8 kg | `units.under` remainder = 0.462 lb |

Edge cases to hold: zero target; inventory with a plate count edited to 0 (V9-shape fallback must engage); unit toggle with an unrepresentable cross-unit target (e.g. 100 kg = 220.46 lb against lb set → nearestDown, annotated — no crash, no silent clamp).

## 8. Rejected Alternatives

- **Persist calculation history** → rejected: pure function; history adds an entity for zero user value. #7 may surface a recents UI later — that is a *new* contract, not an edit of this one.
- **Plate inventory as per-user global settings entity in v1** → rejected: BR-001 defaults + in-sheet edit cover the solo builder; promotion to `GymProfile` is deferred to cloud phase.
- **Half-plate asymmetric loading** → rejected: INV-2 symmetry is a safety invariant, not a UI preference.
- **`nearestUp` as default** → rejected: undershoot is the safe failure mode under fatigue (BR-003).
- **Per-set RPE/notes fields on the calculator** → rejected: set contract is strictly `weight? × reps|duration` (#2); the calculator returns plates, nothing else.

## 9. Downstream Effects

- Feeds #7 (screen blueprint): the calculator renders inside the set-edit bottom sheet's plate preview (#2's 3-tap edit path).
- Feeds #8: this file is the reference implementation target for the port-parity test harness — if a platform reproduces V1–V10, its contract-reading pipeline works.
- Precision floor: every future contract (sessions, PRs, analytics) must be at least this complete before freezing.
