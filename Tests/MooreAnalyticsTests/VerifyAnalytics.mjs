// Seam-1/seam-2 verifier for SC-analytics@1.0.0 (ticket #27).
// Mirrors Sources/MooreAnalytics/AnalyticsEngine.swift in JS so vectors run on
// Windows; fresh in-memory DB per fixture; all analytics derived read-only from
// completed_set + workout_session + exercise + personal_record (INV-A1: no new
// tables — the DB is only ever seeded by the fixture, then queried).
//
// Usage: node Tests/MooreAnalyticsTests/VerifyAnalytics.mjs

import Database from 'better-sqlite3';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const worktreeRoot = join(here, '..', '..');
const FIXT = join(here, 'Fixtures');

// The ONE canonical chain (#32): unique numbers, applied in this order everywhere.
// 0004 (rewritten over the real 0001 shape) lands `exercise.category`, which the
// muscle split reads FROM THE STORED ROW (BR-004 / #32 AC-4). 0009 is required:
// the PR list + History badges read personal_record in its post-0009 canonical
// shape (sessionId present, widened kind CHECK) — legacy 0001 rows would reject
// the fixture kinds outright.
const MIGRATIONS = [
  'Sources/MooreFoundation/Migrations/0001_core.sql',
  'Sources/MooreFoundation/Migrations/0002_warmup_progression.sql',
  'Sources/MooreFoundation/Migrations/0003_import_columns.sql',
  'Sources/MooreExercises/Migrations/0004_exercise_library.sql',
  'Sources/MooreRoutines/Migrations/0005_routines_folders.sql',
  'Sources/MooreRoutines/Migrations/0006_routines_session_link.sql',
  'Sources/MooreProgression/Migrations/0007_progression_full.sql',
  'Sources/MooreRest/Migrations/0008_rest_fields.sql',
  'Sources/MooreRecords/Migrations/0009_personal_records.sql',
  'Sources/MooreWarmup/Migrations/0010_warmup_per_exercise_toggle.sql',
  'Sources/MooreSettings/Migrations/0011_body_metrics.sql',
  'Sources/MooreAnalytics/Migrations/0012_validation_metrics.sql',
].map((p) => join(worktreeRoot, ...p.split('/')));

let failures = 0, passes = 0;
const fail = (m) => { console.error(`FAIL: ${m}`); failures += 1; };
const pass = (m) => { console.log(`PASS: ${m}`); passes += 1; };
const eq = (a, b, label) => (a === b ? pass(label) : fail(`${label}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`));
const EPS = 1e-6;
const approx = (a, b, label) => (Math.abs(a - b) <= EPS ? pass(label) : fail(`${label}: expected ~${b}, got ${a}`));

// ---- §6 UI copy (analytics surfaces the empty state, never a gate) ----
const COPY = {
  'analytics.title': 'Analytics',
  'analytics.empty.trends': 'Log 3 sessions to see trends',
  'analytics.empty.history': 'No sessions yet',
  'analytics.empty.prs': 'No records yet',
  'history.title': 'History',
};

// ---- JS mirror of AnalyticsEngine (AnalyticsEngine.swift is source of truth) ----
const daysFromCivil = (y, m, d) => {
  if (m <= 2) y -= 1;
  const era = Math.floor((y >= 0 ? y : y - 399) / 400);
  const yoe = y - era * 400;
  const doy = Math.floor((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe - 719468;
};
const civilFromDays = (z) => {
  const zs = z + 719468;
  const era = Math.floor((zs >= 0 ? zs : zs - 146096) / 146097);
  const doe = zs - era * 146097;
  const yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365);
  const y = yoe + era * 400;
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const m = mp < 10 ? mp + 3 : mp - 9;
  return { y: m <= 2 ? y + 1 : y, m, d };
};
const pad2 = (n) => String(n).padStart(2, '0');
const dayString = (dn) => { const c = civilFromDays(dn); return `${c.y}-${pad2(c.m)}-${pad2(c.d)}`; };

const E = {
  utcDay: (iso) => String(iso).slice(0, 10),
  dayNumber(day) {
    const parts = String(day).split('-').map(Number);
    if (parts.length !== 3 || parts.some((n) => !Number.isInteger(n))) return 0;
    return daysFromCivil(parts[0], parts[1], parts[2]);
  },
  mondayIndex(dn) { return ((((dn % 7) + 7) % 7) + 3) % 7; },   // 1970-01-01 was a Thursday
  isoWeekKey(day) {
    const dn = E.dayNumber(day);
    const thu = dn + (3 - E.mondayIndex(dn));
    const isoYear = civilFromDays(thu).y;
    const jan4 = daysFromCivil(isoYear, 1, 4);
    const week1Thu = jan4 + (3 - E.mondayIndex(jan4));
    const week = Math.floor((thu - week1Thu) / 7) + 1;
    return `${isoYear}-W${pad2(week)}`;
  },
  epley: (w, r) => w * (1 + r / 30),
  isWorkClass: (c) => (c ?? 'work') === 'work',

  sessionDays(sessions, today, rangeDays) {
    const hi = E.dayNumber(today);
    const lo = hi - (rangeDays - 1);
    const out = {};
    for (const s of sessions) {
      const day = E.utcDay(s.startedAt);
      const dn = E.dayNumber(day);
      if (dn >= lo && dn <= hi) out[s.id] = day;
    }
    return out;
  },

  // BR-001 — qualifying days: live sets with logged actuals, not dropped
  // (status ∈ completed|failed; SC-workout-logging BR-002).
  qualifyingDays(sessions, sets) {
    const dayBySession = {};
    for (const s of sessions) dayBySession[s.id] = E.utcDay(s.startedAt);
    const days = new Set();
    for (const set of sets) {
      if (set.status !== 'completed' && set.status !== 'failed') continue;
      const day = dayBySession[set.sessionId];
      if (day) days.add(day);
    }
    return [...days].sort();
  },
  currentStreak(qualifyingDays, today) {
    const days = new Set(qualifyingDays);
    if (!days.size) return 0;
    let anchor = E.dayNumber(today);
    if (!days.has(dayString(anchor))) {
      anchor -= 1;                                               // yesterday keeps it alive
      if (!days.has(dayString(anchor))) return 0;
    }
    let count = 0, cursor = anchor;
    while (days.has(dayString(cursor))) { count += 1; cursor -= 1; }
    return count;
  },
  adherenceHeader(sessions, sets, today) {
    const todayNum = E.dayNumber(today);
    const countWithin = (n) => {
      const lo = todayNum - (n - 1);
      return sessions.filter((s) => {
        const dn = E.dayNumber(E.utcDay(s.startedAt));
        return dn >= lo && dn <= todayNum;
      }).length;
    };
    return {
      sessionsLast7: countWithin(7),
      sessionsLast30: countWithin(30),
      currentStreak: E.currentStreak(E.qualifyingDays(sessions, sets), today),
    };
  },

  // BR-002 — Epley trend, gap > gapBreakDays breaks the line.
  epleyTrend(sessions, sets, exerciseId, today, rangeDays, gapBreakDays = 7) {
    const window = E.sessionDays(sessions, today, rangeDays);
    const bestByDay = {};
    for (const set of sets) {
      if (set.exerciseId !== exerciseId) continue;
      if (set.status !== 'completed' || !E.isWorkClass(set.setClass)) continue;
      const day = window[set.sessionId];
      if (!day) continue;
      const w = set.actualWeight, r = set.actualReps;
      if (!(w > 0) || !(r > 0)) continue;
      const v = E.epley(w, r);
      bestByDay[day] = day in bestByDay ? Math.max(bestByDay[day], v) : v;
    }
    const points = [];
    let segment = 0, prev = null;
    for (const day of Object.keys(bestByDay).sort()) {
      const dn = E.dayNumber(day);
      if (prev !== null && dn - prev > gapBreakDays) segment += 1;
      points.push({ day, value: bestByDay[day], segment });
      prev = dn;
    }
    return points;
  },

  // BR-003 — weekly tonnage, warmups excluded.
  weeklyTonnage(sessions, sets, today, rangeDays) {
    const window = E.sessionDays(sessions, today, rangeDays);
    const byWeek = {};
    for (const set of sets) {
      if (set.status !== 'completed' || !E.isWorkClass(set.setClass)) continue;
      const day = window[set.sessionId];
      if (!day) continue;
      if (set.actualWeight == null || set.actualReps == null) continue;
      const week = E.isoWeekKey(day);
      byWeek[week] = (byWeek[week] ?? 0) + set.actualWeight * set.actualReps;
    }
    return Object.keys(byWeek).sort().map((week) => ({ week, tonnage: byWeek[week] }));
  },

  // BR-004 — muscle split buckets.
  upperCategories: new Set(['chest', 'back', 'shoulders', 'biceps', 'triceps', 'forearms']),
  lowerCategories: new Set(['quads', 'hamstrings', 'glutes', 'calves']),
  bucket(category) {
    if (category == null) return 'other';
    if (E.upperCategories.has(category)) return 'upper';
    if (E.lowerCategories.has(category)) return 'lower';
    return 'other';
  },
  muscleSplit(sessions, sets, exercises, today, rangeDays) {
    const categoryById = {};
    for (const e of exercises) categoryById[e.id] = e.category;
    const window = E.sessionDays(sessions, today, rangeDays);
    const byBucket = {};
    for (const set of sets) {
      if (set.status !== 'completed' || !E.isWorkClass(set.setClass)) continue;
      const day = window[set.sessionId];
      if (!day) continue;
      if (set.actualWeight == null || set.actualReps == null) continue;
      const bucket = E.bucket(set.exerciseId in categoryById ? categoryById[set.exerciseId] : null);
      byBucket[bucket] = (byBucket[bucket] ?? 0) + set.actualWeight * set.actualReps;
    }
    const total = Object.values(byBucket).reduce((a, b) => a + b, 0);
    if (!(total > 0)) return [];
    return ['upper', 'lower', 'other']
      .filter((name) => (byBucket[name] ?? 0) > 0)
      .map((name) => ({ bucket: name, tonnage: byBucket[name], pct: (byBucket[name] / total) * 100 }));
  },

  // BR-005 — PR list, reverse-chronological with deterministic tie-break.
  prList(rows, exercises) {
    const nameById = {};
    for (const e of exercises) nameById[e.id] = e.name;
    return [...rows]
      .sort((a, b) => {
        if (a.achievedAt !== b.achievedAt) return a.achievedAt > b.achievedAt ? -1 : 1;
        if (a.exerciseId !== b.exerciseId) return a.exerciseId < b.exerciseId ? -1 : 1;
        return a.kind < b.kind ? -1 : 1;
      })
      .map((r) => ({
        id: r.id,
        exerciseId: r.exerciseId,
        exerciseName: nameById[r.exerciseId] ?? '',
        kind: r.kind,
        sessionId: r.sessionId,
        achievedAt: r.achievedAt,
        day: E.utcDay(r.achievedAt),
        value: r.value,
      }));
  },

  // BR-006 — month-grouped History with PR badge counts.
  history(sessions, sets, prs) {
    const setsBySession = {};
    for (const set of sets) (setsBySession[set.sessionId] ??= []).push(set);
    const prCountBySession = {};
    for (const pr of prs) prCountBySession[pr.sessionId] = (prCountBySession[pr.sessionId] ?? 0) + 1;
    const rowsByMonth = {};
    for (const session of sessions) {
      const day = E.utcDay(session.startedAt);
      const month = day.slice(0, 7);
      let tonnage = 0, completedCount = 0;
      for (const set of setsBySession[session.id] ?? []) {
        if (set.status !== 'completed') continue;
        completedCount += 1;
        if (E.isWorkClass(set.setClass) && set.actualWeight != null && set.actualReps != null)
          tonnage += set.actualWeight * set.actualReps;
      }
      (rowsByMonth[month] ??= []).push({
        sessionId: session.id,
        name: session.name ?? null,
        day,
        startedAt: session.startedAt,
        completedCount,
        tonnage,
        prCount: prCountBySession[session.id] ?? 0,
      });
    }
    return Object.keys(rowsByMonth).sort().reverse().map((month) => ({
      month,
      rows: rowsByMonth[month].sort((a, b) => {
        if (a.startedAt !== b.startedAt) return a.startedAt > b.startedAt ? -1 : 1;
        return a.sessionId < b.sessionId ? -1 : 1;
      }),
    }));
  },

  // BR-007 — plan-vs-actual rows in sortOrder.
  sessionDetailRows(sessionId, sets) {
    return sets
      .filter((s) => s.sessionId === sessionId)
      .sort((a, b) => (a.sortOrder !== b.sortOrder ? a.sortOrder - b.sortOrder : (a.id < b.id ? -1 : 1)))
      .map((s) => ({
        setId: s.id, exerciseId: s.exerciseId, sortOrder: s.sortOrder,
        status: s.status, setClass: s.setClass ?? null,
        plannedWeight: s.plannedWeight ?? null, plannedReps: s.plannedReps ?? null, plannedDuration: s.plannedDuration ?? null,
        actualWeight: s.actualWeight ?? null, actualReps: s.actualReps ?? null, actualDuration: s.actualDuration ?? null,
      }));
  },
};

// ---- #43: JS mirror of ValidationMetricsEngine (byte-identical conventions) ----
const V = {
  gateSessionsPerWeek: 2,
  gateWeeksRequired: 8,

  // Mirrors ValidationMetricsEngine.epochSeconds (closed-form, no Date parsing).
  epochSeconds(iso) {
    const tParts = String(iso).split('T');
    if (tParts.length !== 2 || tParts[0].length !== 10) return null;
    const dp = tParts[0].split('-').map(Number);
    if (dp.length !== 3 || dp.some(Number.isNaN)) return null;
    if (dp[1] < 1 || dp[1] > 12 || dp[2] < 1 || dp[2] > 31) return null;
    const dayNum = daysFromCivil(dp[0], dp[1], dp[2]);
    let time = tParts[1];
    if (time.endsWith('Z')) time = time.slice(0, -1);
    let fraction = 0;
    const dot = time.indexOf('.');
    if (dot >= 0) {
      const fracText = time.slice(dot + 1);
      time = time.slice(0, dot);
      if (fracText.length > 0) {
        const f = Number('0.' + fracText);
        if (Number.isNaN(f)) return null;
        fraction = f;
      }
    }
    const hms = time.split(':').map(Number);
    if (hms.length !== 3 || hms.some(Number.isNaN)) return null;
    if (hms[0] < 0 || hms[0] > 23 || hms[1] < 0 || hms[1] > 59 || hms[2] < 0 || hms[2] > 59) return null;
    return dayNum * 86400 + hms[0] * 3600 + hms[1] * 60 + hms[2] + fraction;
  },

  median(values) {
    if (!values.length) return null;
    const sorted = [...values].sort((a, b) => a - b);
    const mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  },

  qualifyingSessionIds(sessions, sets) {
    const completedBySession = new Set();
    for (const s of sets) if (s.status === 'completed') completedBySession.add(s.sessionId);
    return new Set(sessions.map((s) => s.id).filter((id) => completedBySession.has(id)));
  },

  weeklySessionCounts(sessions, sets) {
    const qualifying = V.qualifyingSessionIds(sessions, sets);
    const byWeek = {};
    for (const s of sessions) {
      if (!qualifying.has(s.id)) continue;
      const wk = E.isoWeekKey(E.utcDay(s.startedAt));
      byWeek[wk] = (byWeek[wk] ?? 0) + 1;
    }
    return Object.keys(byWeek).sort().map((week) => ({ week, sessionCount: byWeek[week] }));
  },

  qualifyingWeeks(sessions, sets) {
    return new Set(
      V.weeklySessionCounts(sessions, sets)
        .filter((w) => w.sessionCount >= V.gateSessionsPerWeek)
        .map((w) => w.week));
  },

  currentWeekSessionCount(sessions, sets, today) {
    const week = E.isoWeekKey(today);
    return V.weeklySessionCounts(sessions, sets).find((w) => w.week === week)?.sessionCount ?? 0;
  },

  // Anchor = today's week if qualifying, else the PREVIOUS week (a rest week in
  // progress must not zero a live run); walk back week by week.
  consecutiveQualifyingWeeks(sessions, sets, today) {
    const weeks = V.qualifyingWeeks(sessions, sets);
    if (weeks.size === 0) return 0;
    const weekKeyContaining = (dn) => E.isoWeekKey(dayString(dn));
    const previousWeekKey = (dn) => weekKeyContaining(dn - E.mondayIndex(dn) - 1);
    const todayNum = E.dayNumber(today);
    let anchorWeek = weekKeyContaining(todayNum);
    if (!weeks.has(anchorWeek)) {
      anchorWeek = previousWeekKey(todayNum);
      if (!weeks.has(anchorWeek)) return 0;
    }
    let cursorDay = todayNum;
    while (weekKeyContaining(cursorDay) !== anchorWeek) cursorDay -= 1;
    let count = 0;
    let week = anchorWeek;
    while (weeks.has(week)) {
      count += 1;
      const monday = cursorDay - E.mondayIndex(cursorDay);
      cursorDay = monday - 1;
      week = weekKeyContaining(cursorDay);
    }
    return count;
  },

  // Pooled completedAt deltas (first set of each session excluded) + median
  // whole-session pace. Exposes internals for the speedDetail vectors.
  loggingSpeedProxy(sessions, sets) {
    const bySession = {};
    for (const s of sets) {
      if (s.status === 'completed' && s.completedAt != null) (bySession[s.sessionId] ??= []).push(s);
    }
    const deltas = [];
    let sessionsWithDeltas = 0;
    for (const sessionSets of Object.values(bySession)) {
      const ordered = [...sessionSets].sort((a, b) =>
        a.completedAt !== b.completedAt ? (a.completedAt < b.completedAt ? -1 : 1) : (a.id < b.id ? -1 : 1));
      let prev = null;
      let sessionDeltaCount = 0;
      for (const s of ordered) {
        const t = V.epochSeconds(s.completedAt);
        if (t == null) continue;
        if (prev != null) { deltas.push(t - prev); sessionDeltaCount += 1; }
        prev = t;
      }
      if (sessionDeltaCount > 0) sessionsWithDeltas += 1;
    }
    const perSessionPace = [];
    for (const session of sessions) {
      if (session.endedAt == null) continue;
      const start = V.epochSeconds(session.startedAt);
      const end = V.epochSeconds(session.endedAt);
      if (start == null || end == null || end < start) continue;
      const completed = bySession[session.id]?.length ?? 0;
      if (completed === 0) continue;
      perSessionPace.push((end - start) / completed);
    }
    return {
      medianSecondsPerSet: V.median(deltas),
      medianSessionSecondsPerSet: V.median(perSessionPace),
      pooledDeltaCount: deltas.length,
      sessionsWithDeltas,
    };
  },

  openDays(events) { return [...new Set(events.map((e) => E.utcDay(e.openedAt)))].sort(); },

  weeklyRetention(events) {
    const byWeek = {};
    for (const ev of events) {
      const day = E.utcDay(ev.openedAt);
      (byWeek[E.isoWeekKey(day)] ??= new Set()).add(day);
    }
    return Object.keys(byWeek).sort().map((week) => ({ week, distinctOpenDays: byWeek[week].size }));
  },

  currentWeekOpenDays(events, today) {
    const week = E.isoWeekKey(today);
    return V.weeklyRetention(events).find((w) => w.week === week)?.distinctOpenDays ?? 0;
  },

  // #4 activation trigger: PASS iff streak >= 8 AND both manual confirmations.
  evaluateGate(sessions, sets, today, displacementConfirmed, retentionConfirmed) {
    const hasAny = V.qualifyingWeeks(sessions, sets).size > 0;
    const streak = V.consecutiveQualifyingWeeks(sessions, sets, today);
    const streakMet = streak >= V.gateWeeksRequired;
    let status;
    if (!hasAny) status = 'NOT-STARTED';
    else if (streakMet && displacementConfirmed && retentionConfirmed) status = 'PASS';
    else status = 'IN-PROGRESS';
    return {
      status, weekStreak: streak, streakConditionMet: streakMet,
      displacementConfirmed, retentionConfirmed,
      weeksRequired: V.gateWeeksRequired, sessionsPerWeekRequired: V.gateSessionsPerWeek,
    };
  },
};

// ---- DB plumbing ----
function newDb() {
  const db = new Database(':memory:');
  for (const m of MIGRATIONS) db.exec(readFileSync(m, 'utf8'));
  // #32: no integration patch needed — the rewritten 0004 in the canonical chain
  // adds `exercise.category` over the real 0001 shape; the muscle split below
  // reads it straight off the stored rows (AnalyticsDAO.fetchExercises parity).
  return db;
}

function seedFixture(db, fx) {
  const now = '2026-08-12T00:00:00Z';
  const ie = db.prepare(`INSERT INTO exercise (id, name, exerciseType, category, isCustom, createdAt, updatedAt, deletedAt) VALUES (?, ?, ?, ?, 0, ?, ?, ?)`);
  for (const e of fx.seed.exercises ?? [])
    ie.run(e.id, e.name, e.exerciseType ?? 'strength', e.category ?? null, now, now, e.deleted ? now : null);
  const is = db.prepare(`INSERT INTO workout_session (id, name, startedAt, endedAt, createdAt, updatedAt, deletedAt) VALUES (?, ?, ?, ?, ?, ?, ?)`);
  for (const s of fx.seed.sessions ?? [])
    is.run(s.id, s.name ?? null, s.startedAt, s.endedAt ?? null, now, now, s.deleted ? now : null);
  const ic = db.prepare(`
    INSERT INTO completed_set (id, sessionId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration,
                               actualWeight, actualReps, actualDuration, status, setClass, completedAt, createdAt, updatedAt, deletedAt)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
  const ordBySession = {};
  for (const s of fx.seed.sets ?? []) {
    const ord = ordBySession[s.sessionId] ?? 0;
    ordBySession[s.sessionId] = ord + 1;
    ic.run(s.id, s.sessionId, s.exerciseId, s.sortOrder ?? ord,
      s.plannedWeight ?? null, s.plannedReps ?? null, s.plannedDuration ?? null,
      s.actualWeight ?? null, s.actualReps ?? null, s.actualDuration ?? null,
      s.status, s.setClass ?? null, s.completedAt ?? null, now, now, s.deleted ? now : null);
  }
  const ip = db.prepare(`
    INSERT INTO personal_record (id, exerciseId, sessionId, setId, kind, value, achievedAt, createdAt, updatedAt, deletedAt)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
  for (const p of fx.seed.personalRecords ?? [])
    ip.run(randomUUID(), p.exerciseId, p.sessionId, p.setId ?? null, p.kind, p.value, p.achievedAt, now, now, p.deleted ? now : null);
}

const load = (db) => ({
  sessions: () => db.prepare(`SELECT id, name, startedAt, endedAt FROM workout_session WHERE deletedAt IS NULL ORDER BY startedAt ASC`).all(),
  sets: () => db.prepare(`
    SELECT id, sessionId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration,
           actualWeight, actualReps, actualDuration, status, setClass, completedAt
      FROM completed_set WHERE deletedAt IS NULL ORDER BY sessionId, sortOrder ASC`).all(),
  exercises: () => db.prepare(`SELECT id, name, category FROM exercise ORDER BY id`).all(),
  prs: () => db.prepare(`SELECT id, exerciseId, sessionId, kind, value, achievedAt FROM personal_record WHERE deletedAt IS NULL ORDER BY achievedAt DESC`).all(),
});

// ---- Structured assertions ----
function expectHeader(actual, want, id) {
  eq(actual.sessionsLast7, want.last7, `${id}.last7`);
  eq(actual.sessionsLast30, want.last30, `${id}.last30`);
  eq(actual.currentStreak, want.streak, `${id}.streak`);
}
function expectDays(actual, want, id) {
  eq(JSON.stringify(actual), JSON.stringify(want), `${id}.qualifyingDays`);
}
function expectPoints(actual, want, id) {
  if (actual.length !== want.length) { fail(`${id}.points.length: expected ${want.length}, got ${actual.length} — ${JSON.stringify(actual)}`); return; }
  want.forEach((w, i) => {
    const a = actual[i];
    eq(a.day, w.day, `${id}.point${i}.day`);
    approx(a.value, w.value, `${id}.point${i}.value`);
    eq(a.segment, w.segment, `${id}.point${i}.segment`);
  });
}
function expectWeeks(actual, want, id) {
  if (actual.length !== want.length) { fail(`${id}.weeks.length: expected ${want.length}, got ${actual.length} — ${JSON.stringify(actual)}`); return; }
  want.forEach((w, i) => {
    eq(actual[i].week, w.week, `${id}.week${i}.key`);
    approx(actual[i].tonnage, w.tonnage, `${id}.week${i}.tonnage`);
  });
}
function expectBuckets(actual, want, id, tolerance = 0.1) {
  if (actual.length !== want.length) { fail(`${id}.buckets.length: expected ${want.length}, got ${actual.length} — ${JSON.stringify(actual)}`); return; }
  want.forEach((w, i) => {
    eq(actual[i].bucket, w.bucket, `${id}.bucket${i}.name`);
    approx(actual[i].tonnage, w.tonnage, `${id}.bucket${i}.tonnage`);
    approx(actual[i].pct, w.pct, `${id}.bucket${i}.pct`);
  });
  const sum = actual.reduce((a, b) => a + b.pct, 0);
  Math.abs(sum - 100) <= tolerance
    ? pass(`${id}.buckets.sum-100±${tolerance} (${sum})`)
    : fail(`${id}.buckets.sum: |${sum} - 100| > ${tolerance}`);
}
function expectItems(actual, want, id) {
  if (actual.length !== want.length) { fail(`${id}.items.length: expected ${want.length}, got ${actual.length}`); return; }
  want.forEach((w, i) => {
    const a = actual[i];
    if ('exerciseId' in w) eq(a.exerciseId, w.exerciseId, `${id}.item${i}.exerciseId`);
    if ('exerciseName' in w) eq(a.exerciseName, w.exerciseName, `${id}.item${i}.exerciseName`);
    if ('kind' in w) eq(a.kind, w.kind, `${id}.item${i}.kind`);
    if ('value' in w) approx(a.value, w.value, `${id}.item${i}.value`);
    if ('day' in w) eq(a.day, w.day, `${id}.item${i}.day`);
    if ('sessionId' in w) eq(a.sessionId, w.sessionId, `${id}.item${i}.sessionId`);
  });
}
function expectHistory(actual, want, id) {
  if (actual.length !== want.length) { fail(`${id}.months.length: expected ${want.length}, got ${actual.length} — got ${JSON.stringify(actual.map((m) => m.month))}`); return; }
  want.forEach((wm, mi) => {
    const am = actual[mi];
    eq(am.month, wm.month, `${id}.month${mi}.key`);
    if (am.rows.length !== wm.rows.length) { fail(`${id}.month${mi}.rows.length: expected ${wm.rows.length}, got ${am.rows.length}`); return; }
    wm.rows.forEach((wr, ri) => {
      const ar = am.rows[ri];
      if ('sessionId' in wr) eq(ar.sessionId, wr.sessionId, `${id}.month${mi}.row${ri}.sessionId`);
      if ('day' in wr) eq(ar.day, wr.day, `${id}.month${mi}.row${ri}.day`);
      if ('name' in wr) eq(ar.name, wr.name, `${id}.month${mi}.row${ri}.name`);
      if ('completedCount' in wr) eq(ar.completedCount, wr.completedCount, `${id}.month${mi}.row${ri}.completedCount`);
      if ('tonnage' in wr) approx(ar.tonnage, wr.tonnage, `${id}.month${mi}.row${ri}.tonnage`);
      if ('prCount' in wr) eq(ar.prCount, wr.prCount, `${id}.month${mi}.row${ri}.prCount`);
      if ('badge' in wr) eq(ar.prCount > 0, wr.badge, `${id}.month${mi}.row${ri}.badge(history.badge.pr)`);
    });
  });
}
function expectDetailRows(actual, want, id) {
  if (actual.length !== want.length) { fail(`${id}.rows.length: expected ${want.length}, got ${actual.length}`); return; }
  want.forEach((w, i) => {
    const a = actual[i];
    for (const k of Object.keys(w)) {
      if (typeof w[k] === 'number' && typeof a[k] === 'number') approx(a[k], w[k], `${id}.row${i}.${k}`);
      else eq(a[k], w[k], `${id}.row${i}.${k}`);
    }
  });
}

// ---- INV-A1 / V13 read-path audit: the module must contain no write SQL ----
(function readOnlyAudit() {
  const daoSrc = readFileSync(join(worktreeRoot, 'Sources', 'MooreAnalytics', 'AnalyticsDAO.swift'), 'utf8');
  const engineSrc = readFileSync(join(worktreeRoot, 'Sources', 'MooreAnalytics', 'AnalyticsEngine.swift'), 'utf8');
  const writeSql = /\b(INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|CREATE\s+TABLE|ALTER\s+TABLE|DROP\s+TABLE)\b/i;
  if (writeSql.test(daoSrc)) fail('V13.dao-read-only: write SQL found in AnalyticsDAO.swift');
  else pass('V13.dao-read-only');
  if (writeSql.test(engineSrc)) fail('V13.engine-pure: write SQL found in AnalyticsEngine.swift');
  else pass('V13.engine-pure');
  if (/\.write\s*\{/.test(daoSrc)) fail('V13.dao-no-write-tx: dbQueue.write found in AnalyticsDAO.swift');
  else pass('V13.dao-no-write-tx');
})();

// ---- Fixture runner ----
const files = readdirSync(FIXT).filter((f) => f.endsWith('.json')).sort();
for (const fname of files) {
  const fx = JSON.parse(readFileSync(join(FIXT, fname), 'utf8'));
  console.log(`\n-- ${fname}: ${fx.label ?? ''}`);
  const db = newDb();
  seedFixture(db, fx);
  const L = load(db);
  const fixtureToday = fx.today ?? '2026-08-12';

  for (const v of fx.vectors ?? []) {
    const id = `${fname}.${v.id}`;
    const q = v.query ?? {};
    const today = q.today ?? v.today ?? fixtureToday;
    const rangeDays = q.rangeDays ?? 30;
    const ex = v.expect ?? {};

    switch (q.op) {
      case 'header':
        expectHeader(E.adherenceHeader(L.sessions(), L.sets(), today), ex, id);
        break;
      case 'qualifyingDays':
        expectDays(E.qualifyingDays(L.sessions(), L.sets()), ex.days ?? [], id);
        break;
      case 'trend':
        expectPoints(
          E.epleyTrend(L.sessions(), L.sets(), q.exerciseId, today, rangeDays, q.gapBreakDays ?? 7),
          ex.points ?? [], id);
        break;
      case 'tonnage':
        expectWeeks(E.weeklyTonnage(L.sessions(), L.sets(), today, rangeDays), ex.weeks ?? [], id);
        break;
      case 'split':
        expectBuckets(E.muscleSplit(L.sessions(), L.sets(), L.exercises(), today, rangeDays), ex.buckets ?? [], id, ex.sumTolerance ?? 0.1);
        break;
      case 'bucketMap': {
        for (const [cat, want] of Object.entries(ex.map ?? {}))
          eq(E.bucket(cat === 'NULL' ? null : cat), want, `${id}.bucket(${cat})`);
        break;
      }
      case 'epley':
        approx(E.epley(q.weight, q.reps), ex.value, id);
        break;
      case 'prList':
        expectItems(E.prList(L.prs(), L.exercises()), ex.items ?? [], id);
        break;
      case 'history':
        expectHistory(E.history(L.sessions(), L.sets(), L.prs()), ex.months ?? [], id);
        break;
      case 'detail': {
        const rows = E.sessionDetailRows(q.sessionId, L.sets());
        expectDetailRows(rows, ex.rows ?? [], id);
        if (ex.sparkline !== undefined) {
          const exerciseId = rows.length ? rows[0].exerciseId : q.sparklineExerciseId;
          expectPoints(E.epleyTrend(L.sessions(), L.sets(), exerciseId, today, 36500), ex.sparkline ?? [], `${id}.sparkline`);
        }
        break;
      }
      case 'emptyState': {
        // BR-008: everything renders empty; zero-data never gates the surface.
        const sessions = L.sessions(), sets = L.sets(), prs = L.prs(), exercises = L.exercises();
        const header = E.adherenceHeader(sessions, sets, today);
        eq(header.sessionsLast7, 0, `${id}.last7`);
        eq(header.sessionsLast30, 0, `${id}.last30`);
        eq(header.currentStreak, 0, `${id}.streak`);
        eq(E.weeklyTonnage(sessions, sets, today, rangeDays).length, 0, `${id}.tonnage-empty`);
        eq(E.muscleSplit(sessions, sets, exercises, today, rangeDays).length, 0, `${id}.split-empty`);
        eq(E.prList(prs, exercises).length, 0, `${id}.prlist-empty`);
        eq(E.history(sessions, sets, prs).length, 0, `${id}.history-empty`);
        for (const eid of (exercises.map((e) => e.id)))
          eq(E.epleyTrend(sessions, sets, eid, today, rangeDays).length, 0, `${id}.trend-empty.${eid}`);
        eq(COPY[ex.copyKey ?? 'analytics.empty.trends'], ex.copy, `${id}.copy(${ex.copyKey ?? 'analytics.empty.trends'})`);
        break;
      }
      default:
        fail(`${id}: unknown op ${q.op}`);
    }
  }

  // #43: self-validation vectors (ValidationMetricsEngine mirror).
  for (const v of fx.validationVectors ?? []) {
    const id = `${fname}.${v.id}`;
    const q = v.query ?? {};
    const today = q.today ?? fx.today ?? '2026-08-12';
    const ex = v.expect ?? {};
    const sessions = L.sessions(), sets = L.sets();
    switch (v.op) {
      case 'weeklyCounts': {
        const weeks = V.weeklySessionCounts(sessions, sets)
          .map((w) => ({ week: w.week, count: w.sessionCount }));
        eq(JSON.stringify(weeks), JSON.stringify(ex.weeks ?? []), `${id}.weeks`);
        break;
      }
      case 'streak':
        eq(V.consecutiveQualifyingWeeks(sessions, sets, today), ex.streak, `${id}.streak`);
        break;
      case 'currentWeekCount':
        eq(V.currentWeekSessionCount(sessions, sets, today), ex.count, `${id}.count`);
        break;
      case 'gate': {
        const g = V.evaluateGate(sessions, sets, today, q.displacementConfirmed ?? false, q.retentionConfirmed ?? false);
        eq(g.status, ex.status, `${id}.status`);
        eq(g.weekStreak, ex.weekStreak, `${id}.weekStreak`);
        eq(g.streakConditionMet, ex.streakConditionMet, `${id}.streakConditionMet`);
        break;
      }
      case 'speed': {
        const sp = V.loggingSpeedProxy(sessions, sets);
        approx(sp.medianSecondsPerSet, ex.medianSecondsPerSet, `${id}.medianSecondsPerSet`);
        approx(sp.medianSessionSecondsPerSet, ex.medianSessionSecondsPerSet, `${id}.medianSessionSecondsPerSet`);
        break;
      }
      case 'speedDetail': {
        const sp = V.loggingSpeedProxy(sessions, sets);
        eq(sp.sessionsWithDeltas, ex.sessionsWithDeltas, `${id}.sessionsWithDeltas`);
        eq(sp.pooledDeltaCount, ex.pooledDeltaCount, `${id}.pooledDeltaCount`);
        break;
      }
      default:
        fail(`${id}: unknown validation op ${v.op}`);
    }
  }
  db.close();
}

console.log('');
if (failures === 0) { console.log(`ALL ANALYTICS FIXTURES PASS (${passes} checks)`); process.exit(0); }
console.error(`${failures} check(s) failed`); process.exit(1);
