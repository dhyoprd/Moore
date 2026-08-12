# Contract: Analytics Tab + History

```yaml
---
contractId: "SC-analytics"
version: "1.0.0"
status: frozen
date: "2026-08-12"
source: "#27"
supersedes: null
supersededBy: null
---
```

The Analytics tab and History aggregation per #7 + #3: **strictly derived, read-only queries**. This contract creates **no tables, no columns, no migrations** — #3 invariant 5 ("analytics never persisted"; SC-foundation §3c: "no derived fields are stored; all analytics recompute from `CompletedSet` at read time") is the whole data story. Every number on the Analytics tab is recomputed from `completed_set` + `workout_session` + `exercise` + `personal_record` on each read.

Consumes `SC-foundation@1.0.0` (schema + invariants, migrations 0001–0003), `SC-workout-logging@1.0.0` (CompletedSet lifecycle, dual planned/actual columns, `setClass`), `SC-exercises@1.0.0` (`Exercise.category` buckets), `SC-prs@1.0.0` (`personal_record` post-0008 shape, `personal_record_session_idx` badge probe, `history.badge.pr` key). Adds nothing to the schema.

## 2. State Machine

**None for this contract.** Analytics holds no state; every function is a pure derivation over read inputs (seam-1) or a read-only SQL query (seam-2). There is no write path in this module — `AnalyticsDAO` exposes `read` calls only, and the verifier asserts no CREATE/ALTER/INSERT/UPDATE surface exists in the module.

## 3. Data Schema

**(a) Tables: none created.** Read surface, all pre-existing:

| Table | Read for | Filter |
|---|---|---|
| `workout_session` | streak/adherence header, week/month attribution of sets, History rows | `deletedAt IS NULL` (INV-3) |
| `completed_set` | every metric: streak days, e1RM trend, tonnage, muscle split, plan-vs-actual detail | `deletedAt IS NULL`; `status`/`setClass` gates per §4 |
| `exercise` | `category` → muscle-split bucket; name resolution | **names resolve including tombstones** (SC-exercises INV-L3); category of a tombstoned exercise still buckets its historic volume |
| `personal_record` (post-0008 shape) | PR list, History PR badges | `deletedAt IS NULL`; badge probe on `sessionId` via `personal_record_session_idx` (SC-prs §3a) |

**(b) Column-shape notes.**

- Timestamps are ISO-8601 UTC text (SC-foundation §3b). All calendar math in this contract uses the **UTC calendar day** — the leading `YYYY-MM-DD` of the timestamp. No local-timezone conversion: deterministic across platforms and testable byte-identically (§9, Android port).
- `exercise.category` is the SC-exercises §3b enum (`chest, back, shoulders, biceps, triceps, forearms, core, quads, hamstrings, glutes, calves, fullBody, cardio, other`; NULL = unclassified). Integration note: 0001's `exercise` predates that column and 0004 cannot apply over 0001 (its indexes reference the snake_case shape); the seam-2 verifier therefore adds the column with the one-line ALTER prescribed by `Sources/MooreExercises/Migrations-DEPENDS-ON-19.md` (conflict checklist #2). The DAO reads `category` by name; the app-level migration integrator owns landing it in the shipping DB.
- `personal_record` is read in the **post-0008 canonical shape** (`sessionId` present, kinds `max_1rm|max_volume|max_reps|max_duration`).

**(c) Invariants (additive to SC-foundation §3c)**

- **INV-A1 (never persisted).** No analytics value is ever written to any table. No helper/summary/cache tables, no materialized aggregates — the event timeline in `CompletedSet` is the only storage (SC-foundation invariant 5; SC-prs INV-PR2's same reasoning).
- **INV-A2 (tombstone discipline).** Every read filters `deletedAt IS NULL` on sessions, sets, and PR rows (INV-3); exercise **name** resolution is the one exception and includes tombstones (INV-L3).
- **INV-A3 (honest time axis).** Time-series outputs carry only real observations: weeks/days with no qualifying data are *absent*, never zero-filled — no phantom flat lines (#27 AC: "skips intermediate zero-values").
- **INV-A4 (window discipline).** All range queries are inclusive calendar-day windows `[today − (rangeDays − 1), today]` evaluated in UTC days.

## 4. Business Rules

- **BR-001 (streak = consecutive qualifying calendar days).** A calendar day *qualifies* iff it carries ≥1 live set with logged actuals that was not dropped — `status ∈ {completed, failed}` (SC-workout-logging BR-002: failures record actuals; `dropped`/`planned` rows carry none, INV-W2). The current streak is the count of consecutive qualifying days ending at the anchor: **anchor = today if today qualifies, else yesterday** (a rest day in progress must not zero a live streak); if neither qualifies the streak is 0. Any gap > 1 day between qualifying days resets the run. Week boundaries are invisible to the streak — it is day-based, not week-based (cross-week runs count straight through).
- **BR-002 (Epley 1RM trend per exercise).** One point per session that contains ≥1 qualifying set for the exercise: qualifying = `status='completed'` AND `coalesce(setClass,'work')='work'` AND `actualWeight > 0` AND `actualReps > 0` (SC-prs BR-001/BR-004's gate — warmups and bodyweight rows never plot). Point value = **max over the session's qualifying sets of `actualWeight × (1 + actualReps/30)`** (Epley, unrounded). x = UTC day of `workout_session.startedAt`; two sessions the same day merge into one point (max wins). Points ascend by day. **A gap > 7 days between consecutive points breaks the line** (new segment); gap = day-number difference, so gap = 7 stays connected, gap = 8 breaks. No interpolated or zero points are ever inserted between sessions (INV-A3).
- **BR-003 (weekly tonnage, warmups excluded).** Per ISO-8601 week (Monday–Sunday; week key = ISO week-year + week, e.g. `2026-W33`) of `workout_session.startedAt`: `Σ actualWeight × actualReps` over sets with `status='completed'`, `setClass ≠ 'warmup'` (NULL coalesces to `work`, INV-6), and both actuals non-NULL. **Ruling vs SC-foundation BR-006:** foundation's generic "volume aggregate" includes warmups; the ticket #27 AC explicitly defines tonnage as warmup-excluded, and the ticket rules — this metric is work-set tonnage. Weeks with zero qualifying volume are absent (INV-A3). Failed/dropped/planned sets never count (failed actuals are progression signal, not volume — #3).
- **BR-004 (muscle split from category buckets).** Bucket map over `exercise.category`: **upper** = {chest, back, shoulders, biceps, triceps, forearms}; **lower** = {quads, hamstrings, glutes, calves}; **other** = everything else (core, fullBody, cardio, other, NULL/unclassified). Bucket tonnage uses BR-003's exact set gate. Output = non-zero buckets in fixed order `upper, lower, other`, each with unrounded `pct = bucketTonnage / totalTonnage × 100`. Percentages sum to exactly 100 within float epsilon (AC bound: ±0.1%). Zero total tonnage → empty output (empty state, BR-008).
- **BR-005 (PR list, reverse-chronological).** Live `personal_record` rows ordered by `achievedAt DESC`; deterministic tie-break `exerciseId ASC, kind ASC`. Each item resolves the exercise display name (INV-L3 — tombstoned exercises still name their PR) and carries kind, value, `achievedAt` day, and `sessionId` (deep link per #27).
- **BR-006 (History, month-grouped).** Live sessions grouped by UTC month of `startedAt` (`YYYY-MM`); months descend; rows within a month descend by `startedAt` (tie-break `id`). Each row carries: display name (session `name`, NULL-tolerant), day, `completedCount` (rows with `status='completed'`, any class), row tonnage (BR-003's gate), and **PR badge count** = live `personal_record` rows with `sessionId = session.id` (SC-prs §6 `history.badge.pr` renders when count > 0; the badge probe rides `personal_record_session_idx`).
- **BR-007 (session detail: plan-vs-actual + sparkline).** The detail read lists the session's live sets in `sortOrder ASC` (SC-foundation BR-005) with the dual columns side-by-side — `plannedWeight/plannedReps/plannedDuration` vs `actualWeight/actualReps/actualDuration`, plus `status` and `setClass` — exactly INV-5's shape (plan and actuals live in separate columns forever; failed rows show their recorded actuals per SC-workout-logging BR-002). Per-exercise e1RM sparkline = BR-002 points for that exercise over full history (no window), segment info intact.
- **BR-008 (empty is rendered, never gated).** With zero data every section renders its empty container with §6 copy — **no unlock threshold** (#14's rule; the "Log 3 sessions…" line is encouragement, not a gate: the containers are present from session zero). Zero-qualifying-days streak reads 0, not "hidden".
- **BR-009 (range window).** `rangeDays` defaults to 30 ("last 30 days **or less**"): any window size renders the same shapes with fewer points; a session outside the window contributes to nothing in the windowed queries (trend, tonnage, split, header counts). History and PR list are unwindowed (full log).
- **BR-010 (session counts).** Header `sessionsLastN` = live sessions whose `startedAt` UTC day lies in `[today − (N − 1), today]` — 7-day and 30-day variants (ticket: "7-day / 30-day session counts").

## 5. API Contract

`MooreAnalytics` module; depends on GRDB (seam-2) and Foundation only (seam-1). Engine is seam-1 (pure, closed-form, byte-identical across platforms); DAO is seam-2 (GRDB, read-only).

```swift
public struct AnalyticsSession: Equatable, Sendable {
    public var id: String
    public var name: String?
    public var startedAt: String            // ISO-8601 UTC
    public var endedAt: String?
}

public struct AnalyticsSet: Equatable, Sendable {
    public var id, sessionId, exerciseId: String
    public var sortOrder: Int
    public var plannedWeight: Double?
    public var plannedReps: Int?
    public var plannedDuration: Int?
    public var actualWeight: Double?
    public var actualReps: Int?
    public var actualDuration: Int?
    public var status: String               // planned|completed|failed|dropped
    public var setClass: String?            // nil ⇔ 'work' (INV-6)
    public var completedAt: String?
}

public struct ExerciseInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    public var category: String?            // SC-exercises §3b enum; NULL = unclassified
}

public struct PRRow: Equatable, Sendable {  // personal_record post-0008, live rows
    public var id, exerciseId, sessionId, kind, achievedAt: String
    public var value: Double
}

public struct TrendPoint: Equatable, Sendable { public var day: String; public var value: Double; public var segment: Int }
public struct WeekTonnage: Equatable, Sendable { public var week: String; public var tonnage: Double }
public struct MuscleBucket: Equatable, Sendable { public var bucket: String; public var tonnage: Double; public var pct: Double }
public struct PRListItem: Equatable, Sendable {
    public var id, exerciseId, exerciseName, kind, sessionId, achievedAt, day: String
    public var value: Double
}
public struct HistoryRow: Equatable, Sendable {
    public var sessionId: String
    public var name: String?
    public var day: String
    public var startedAt: String
    public var completedCount: Int
    public var tonnage: Double
    public var prCount: Int                 // > 0 ⇒ history.badge.pr renders (SC-prs §6)
}
public struct HistoryMonth: Equatable, Sendable { public var month: String; public var rows: [HistoryRow] }
public struct PlanActualRow: Equatable, Sendable { /* §BR-007 dual columns + status/setClass/sortOrder */ }
public struct AdherenceHeader: Equatable, Sendable { public var sessionsLast7: Int; public var sessionsLast30: Int; public var currentStreak: Int }

public enum AnalyticsEngine {
    // Closed-form UTC day/week math (mirrored byte-identically by the JS verifier).
    public static func utcDay(_ iso: String) -> String                       // "YYYY-MM-DD" prefix
    public static func dayNumber(_ day: String) -> Int                       // days since 1970-01-01
    public static func isoWeekKey(_ day: String) -> String                   // "2026-W33"

    public static func epley1RM(weight: Double, reps: Int) -> Double         // w × (1 + r/30), unrounded

    public static func qualifyingDays(sessions: [AnalyticsSession], sets: [AnalyticsSet]) -> [String]   // BR-001
    public static func currentStreak(qualifyingDays: [String], today: String) -> Int                    // BR-001
    public static func adherenceHeader(sessions: [AnalyticsSession], sets: [AnalyticsSet], today: String) -> AdherenceHeader  // BR-001/BR-010

    public static func epleyTrend(sessions: [AnalyticsSession], sets: [AnalyticsSet], exerciseId: String,
                                  today: String, rangeDays: Int, gapBreakDays: Int = 7) -> [TrendPoint] // BR-002
    public static func weeklyTonnage(sessions: [AnalyticsSession], sets: [AnalyticsSet],
                                     today: String, rangeDays: Int) -> [WeekTonnage]                    // BR-003
    public static func bucket(forCategory category: String?) -> String                                  // BR-004
    public static func muscleSplit(sessions: [AnalyticsSession], sets: [AnalyticsSet],
                                   exercises: [ExerciseInfo], today: String, rangeDays: Int) -> [MuscleBucket]  // BR-004
    public static func prList(rows: [PRRow], exercises: [ExerciseInfo]) -> [PRListItem]                 // BR-005
    public static func history(sessions: [AnalyticsSession], sets: [AnalyticsSet], prs: [PRRow]) -> [HistoryMonth]  // BR-006
    public static func sessionDetailRows(sessionId: String, sets: [AnalyticsSet]) -> [PlanActualRow]    // BR-007
}

public struct AnalyticsDAO: Sendable {          // seam-2, read-only (INV-A1)
    public init(dbQueue: DatabaseQueue)
    public func fetchSessions() throws -> [AnalyticsSession]
    public func fetchSets() throws -> [AnalyticsSet]
    public func fetchExercises() throws -> [ExerciseInfo]        // tombstones included (INV-L3 names)
    public func fetchPRRows() throws -> [PRRow]
    public func adherenceHeader(today: String) throws -> AdherenceHeader
    public func epleyTrend(exerciseId: String, today: String, rangeDays: Int) throws -> [TrendPoint]
    public func weeklyTonnage(today: String, rangeDays: Int) throws -> [WeekTonnage]
    public func muscleSplit(today: String, rangeDays: Int) throws -> [MuscleBucket]
    public func prList() throws -> [PRListItem]
    public func history() throws -> [HistoryMonth]
    public func sessionDetail(sessionId: String, today: String) throws
        -> (rows: [PlanActualRow], sparkline: [TrendPoint])      // BR-007, sparkline unwindowed
}
```

## 6. UI Copy

Keyed per #6; voice per #17 (declarative, no exclamation marks). Dynamic values use `{placeholder}`.

| Key | String |
|---|---|
| `analytics.title` | "Analytics" |
| `analytics.header.last7` | "{n} sessions · last 7 days" |
| `analytics.header.last30` | "{n} sessions · last 30 days" |
| `analytics.streak.title` | "Current streak" |
| `analytics.streak.days` | "{n} days" |
| `analytics.streak.none` | "No streak yet" |
| `analytics.trend.title` | "Est. 1RM trend" |
| `analytics.tonnage.title` | "Weekly tonnage" |
| `analytics.split.title` | "Muscle split" |
| `analytics.split.bucket.upper` | "Upper" |
| `analytics.split.bucket.lower` | "Lower" |
| `analytics.split.bucket.other` | "Other" |
| `analytics.prs.title` | "Personal records" |
| `analytics.empty.trends` | "Log 3 sessions to see trends" |
| `analytics.empty.history` | "No sessions yet" |
| `analytics.empty.prs` | "No records yet" |
| `history.title` | "History" |
| `history.monthHeader` | "{monthName} {year}" |
| `history.session.sets` | "{n} sets" |
| `history.badge.pr` | "PR" *(owned by SC-prs §6; cited here for the badge render)* |
| `history.detail.planHeader` | "Planned" |
| `history.detail.actualHeader` | "Actual" |

## 7. Acceptance Criteria

Fixtures under `Tests/MooreAnalyticsTests/Fixtures/*.json`; `VerifyAnalytics.mjs` runs them against in-memory SQLite (fresh DB per fixture; migrations 0001–0003, 0005, 0006, 0007-rest, 0008 + the documented one-line `exercise.category` integration patch) through a JS mirror of `AnalyticsEngine`.

| # | Setup | Action | Expected | Cites |
|---|---|---|---|---|
| V1 | Zero sessions, zero sets. | Header + every query. | Streak 0, last7/last30 = 0; trend/tonnage/split/PR list/History all empty; empty containers render with `analytics.empty.trends` = "Log 3 sessions to see trends" — no unlock gate. | BR-008, AC-1 |
| V2 | 3 sessions (08-10/11/12) × bench (chest) + squat (quads), ascending loads. | Trend + tonnage + split + header. | Bench e1RM 70 → 72.917 → 75.833 (one segment); squat 93.333 → 96.25 → 99.167; week `2026-W33` tonnage 2175; split upper 43.103% / lower 56.897% (sum 100 ± 0.1); header 3/3/streak 3. | BR-002, BR-003, BR-004, AC-2 |
| V3 | Window queries with `rangeDays` 30 and 7. | Trend/tonnage at both windows. | Shapes identical, content scoped: 7-day window renders "last 30 days or less" correctly. | BR-009, AC-3 |
| V4 | Bench sessions 07-01, 07-08 (gap 7), 07-17 (gap 9). | Trend, `rangeDays=60`. | Points `[07-01, 07-08]` segment 0, `[07-17]` segment 1; exactly 3 points — no zero-value interpolation across the gap. | BR-002, INV-A3, AC-4 |
| V5 | 5 exercises across chest/back/quads/core/NULL-category, known volumes. | Muscle split. | upper 38.462%, lower 30.769%, other 30.769%; Σ = 100 within ±0.1; fixed bucket order; warmup rows excluded from bucketing. | BR-004, AC-5 |
| V6 | One session: warmup 20×15, work 100×5, NULL-class 100×3, failed 100×4, dropped, planned, tombstoned completed 100×5. | Weekly tonnage. | `2026-W33` = 800 — warmup (300), failed, dropped, planned, tombstoned all excluded; NULL setClass counts as work (INV-6). | BR-003, AC-6 |
| V7 | Qualifying days 08-07…08-10 (Fri→Mon, crosses W32→W33), dropped-only 08-11, completed 08-12, failed-only 08-05. | Streak at several `today`s. | today=08-10 → 4 (cross-week run counts straight through); today=08-12 → 1 (dropped-only day is a gap); today=08-13 → 1 (anchor = yesterday); today=08-20 → 0; failed-only day qualifies, dropped-only never does. | BR-001, AC-9 |
| V8 | Sessions in 2026-08 (×2), 2026-07 (×2), 2026-06 (×1) + one tombstoned August session. | History. | Months `[2026-08, 2026-07, 2026-06]` descending; rows date-descending within each month; tombstoned session absent. | BR-006, INV-A2, AC-7 |
| V9 | Session with planned vs actual diverged across completed/failed/dropped/planned rows. | Session detail. | Dual-column rows in sortOrder: planned intact (INV-W3), actuals as logged, failed row shows its recorded actuals; sparkline = BR-002 points for the exercise. | BR-007, INV-5, AC-8 |
| V10 | 5 live PR rows across 3 sessions incl. one on a tombstoned exercise + an achievedAt tie. | PR list + History badges. | Reverse-chronological with deterministic tie-break; tombstoned exercise's name resolves (INV-L3); per-session badge counts 1/2/2 drive `history.badge.pr`. | BR-005, BR-006, AC-7 |
| V11 | One session: sets 100×3, 90×8, warmup 120×1, NULL-weight set. | Trend point math. | Session point = max Epley = 114 (from 90×8, not the heaviest 100×3 = 110); warmup 124 and NULL-weight rows invisible. | BR-002, AC-9 |
| V12 | Sessions 06-01, 07-20, 08-01, 08-10; today 08-12. | Trend/tonnage, `rangeDays=30`. | 06-01 excluded by the window; weeks `W30, W31, W33` present, `W32` absent (no zero-fill); trend segments break at 12-day and 9-day gaps. | BR-009, INV-A3, AC-3/4 |
| V13 | Everything above. | Read-path audit. | Engine is pure closed-form (no I/O); DAO issues SELECTs only; no table, column, or row is created or mutated by any analytics call. | INV-A1, AC-10 |

Edge cases held: exercise with zero history → empty trend (no crash); two sessions the same day merge to one trend point (max); streak with no qualifying days = 0; split with zero total tonnage = empty; PR list with zero rows = empty.

## 8. Rejected Alternatives

- **Pre-aggregated summary tables (daily_volume, weekly_stats, streak_cache)** → rejected at #3 invariant 5: analytics never persisted; every aggregate derives from `CompletedSet` at read. Caches drift the moment an edit/delete re-derives history (SC-prs BR-007/BR-008), and the read volume (hundreds of sessions, not millions) makes derivation free.
- **Warmups included in tonnage (SC-foundation BR-006's generic volume rule)** → rejected for *this metric* by explicit ticket AC: tonnage is work-set volume; a 20 kg warmup × 15 must not inflate the week. Foundation BR-006 still governs any other "volume" aggregate; the divergence is ruled here, not silently.
- **Zero-filled time axes (a 0 point per empty week/day)** → rejected: manufactures phantom flat lines and misrepresents rest weeks (#27 "visually honest"); gaps break the line instead (BR-002/INV-A3).
- **Streak anchored strictly to today** → rejected: at 9 a.m. before training the user's live streak would read 0 — motivational sabotage; the yesterday-anchor keeps it honest and alive (BR-001).
- **Unlock thresholds ("log N sessions to unlock Analytics")** → rejected per #14: the tab renders but-empty from session zero; the copy invites, never gates (BR-008).
- **Week-based streak (SC-routines' chip)** → rejected: the routines chip counts consecutive *weeks* for scheduling; the analytics header counts consecutive *days* for adherence — different jobs, both derived, no shared state.
- **Local-timezone calendar math** → rejected: timestamps are UTC text by foundation rule; UTC-day math is deterministic and byte-identical for the Android port (§9).

## 9. Downstream Effects

- **Feeds #29 (haptic drivers):** analytics fires no cues — it is a read surface; nothing to dispatch.
- **Feeds #28 (Settings):** no settings surface in v1 analytics; range windows are caller parameters, not preferences.
- **Feeds #8 (Android port):** frozen at v1.0.0; `AnalyticsEngine` is closed-form pure (day/week math included) and must be implemented byte-identical from this file; §6 keys survive verbatim.
- **Consumed upstream:** `personal_record_session_idx` (SC-prs §3a) is the badge probe; `history.badge.pr` (SC-prs §6) the badge copy; `Exercise.category` (SC-exercises §3b) the split buckets; INV-5/INV-W3 (SC-workout-logging) the plan-vs-actual columns.
- **Future #30 import:** imported sessions flow through the same derivation automatically — no analytics change needed on import (INV-A1's payoff).
