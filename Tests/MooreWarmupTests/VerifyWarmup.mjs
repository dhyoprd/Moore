// Seam-1/2 verifier for SC-warmup@1.0.0 (ticket #25).
// Fresh in-memory DB per fixture (full canonical chain 0001–0011, #32).
// Mirrors WarmupRamp.derive / WarmupMaterialize.apply in JS so vectors run on
// Windows without an Apple toolchain; test names cite BR IDs per template §7.
//
// Usage: node Tests/MooreWarmupTests/VerifyWarmup.mjs

import Database from 'better-sqlite3';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const worktreeRoot = join(here, '..', '..');
const fixturesDir = join(here, 'Fixtures');

// The ONE canonical chain (#32): unique numbers, applied in this order everywhere.
const MIGRATIONS = [
  ['MooreFoundation', '0001_core.sql'],
  ['MooreFoundation', '0002_warmup_progression.sql'],
  ['MooreFoundation', '0003_import_columns.sql'],
  ['MooreExercises', '0004_exercise_library.sql'],
  ['MooreRoutines', '0005_routines_folders.sql'],
  ['MooreRoutines', '0006_routines_session_link.sql'],
  ['MooreProgression', '0007_progression_full.sql'],
  ['MooreRest', '0008_rest_fields.sql'],
  ['MooreRecords', '0009_personal_records.sql'],
  ['MooreWarmup', '0010_warmup_per_exercise_toggle.sql'],
  ['MooreSettings', '0011_body_metrics.sql'],
];

const INVENTORIES = {
  kg: [25, 20, 15, 10, 5, 2.5, 1.25],
  lb: [45, 35, 25, 10, 5, 2.5],
};

let failures = 0, passes = 0;
const fail = (m) => { console.error(`FAIL: ${m}`); failures += 1; };
const pass = (m) => { console.log(`PASS: ${m}`); passes += 1; };
const ok = (cond, label) => (cond ? pass(label) : fail(label));
const closeTo = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps;
const uuid = () => crypto.randomUUID();
const now = () => new Date().toISOString();

// ---------------------------------------------------------------------------
// JS mirror of Sources/MooreWarmup/WarmupRamp.swift (BR-003..BR-007).
// ---------------------------------------------------------------------------
function greedyPerSide(perSide, inventory) {
  if (perSide < -1e-9) return null;
  let remaining = perSide;
  const used = [];
  for (const plate of inventory) {
    while (remaining >= plate - 1e-9) { used.push(plate); remaining -= plate; }
  }
  return used;
}

function nearestDown(target, barWeight, plateInventory) {
  const inventory = plateInventory.filter((p) => p > 0).sort((a, b) => b - a);
  if (!inventory.length) return target >= barWeight ? barWeight : null;
  if (target < barWeight) return null;
  const used = greedyPerSide((target - barWeight) / 2, inventory);
  if (!used) return barWeight;
  let weight = barWeight + 2 * used.reduce((s, x) => s + x, 0);
  while (weight > target + 1e-9) {
    const smallest = Math.min(...used);
    if (!Number.isFinite(smallest)) break;
    used.splice(used.lastIndexOf(smallest), 1);
    weight = barWeight + 2 * used.reduce((s, x) => s + x, 0);
  }
  return weight;
}

function derive(workingWeight, barWeight, plateInventory) {
  if (workingWeight == null || !(workingWeight > barWeight)) return [];
  const rows = [{ weight: barWeight, reps: 10 }];
  const heavy = workingWeight >= 5 * barWeight;
  const path = heavy
    ? [[0.40, 5], [0.65, 3], [0.85, 2]]
    : [[0.50, 5], [0.75, 3]];
  const kept = [];
  for (let i = 0; i < path.length; i++) {
    const [pct, reps] = path[i];
    const rounded = nearestDown(pct * workingWeight, barWeight, plateInventory);
    // BR-007.1: nil (target < bar) and ≤bar rounding are equivalent "dropped".
    if (rounded == null || rounded <= barWeight) {
      if (!heavy && i === 0) return rows;                           // BR-007.2 collapse
      continue;
    }
    if (kept.length && rounded <= kept[kept.length - 1].weight) continue; // BR-007.3
    kept.push({ weight: rounded, reps });
  }
  return rows.concat(kept);
}

// ---------------------------------------------------------------------------
// DB harness: fresh DB per fixture; stamp = work-row copy per SC-workout-logging;
// warmupApply = JS mirror of Sources/MooreWarmup/Materialize.swift.
// ---------------------------------------------------------------------------
function newDb() {
  const db = new Database(':memory:');
  for (const [module, name] of MIGRATIONS) {
    db.exec(readFileSync(join(worktreeRoot, 'Sources', module, 'Migrations', name), 'utf8'));
  }
  return db;
}

const insertExercise = (db, id) =>
  db.prepare(`INSERT INTO exercise (id, name, exerciseType, isCustom, createdAt, updatedAt)
              VALUES (?, ?, 'strength', 0, ?, ?)`).run(id, id, now(), now());

const insertRoutine = (db, id) =>
  db.prepare(`INSERT INTO routine (id, name, sortOrder, createdAt, updatedAt)
              VALUES (?, ?, 0, ?, ?)`).run(id, id, now(), now());

function insertSession(db, routineId = null) {
  const id = uuid();
  db.prepare(`INSERT INTO workout_session (id, routineId, startedAt, createdAt, updatedAt)
              VALUES (?, ?, ?, ?, ?)`).run(id, routineId, now(), now(), now());
  return id;
}

function insertWorkSet(db, sessionId, exerciseId, sortOrder, weight, reps, setClass = 'work') {
  db.prepare(`INSERT INTO completed_set
      (id, sessionId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration,
       actualWeight, actualReps, actualDuration, status, setClass, completedAt,
       createdAt, updatedAt, deletedAt)
    VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, 'planned', ?, NULL, ?, ?, NULL)`)
    .run(uuid(), sessionId, exerciseId, sortOrder, weight, reps, setClass, now(), now());
}

function upsertScheme(db, { routineId, exerciseId, warmupEnabled }) {
  db.prepare(`INSERT INTO progression_scheme (id, routineId, exerciseId, scheme, warmupEnabled, createdAt, updatedAt)
              VALUES (?, ?, ?, 'none', ?, ?, ?)`)
    .run(uuid(), routineId, exerciseId, warmupEnabled, now(), now());
}

const isEnabled = (db, routineId, exerciseId) => {
  if (!routineId) return false;
  const r = db.prepare(`SELECT warmupEnabled FROM progression_scheme
                        WHERE routineId = ? AND exerciseId = ? AND deletedAt IS NULL LIMIT 1`)
              .get(routineId, exerciseId);
  return (r?.warmupEnabled ?? 0) === 1;
};

function warmupApply(db, sessionId, routineId, barWeight, plateInventory) {
  if (!routineId) return;                                          // BR-002
  const slices = db.prepare(`
    SELECT exerciseId,
           MIN(sortOrder) AS minSort,
           MAX(CASE WHEN setClass IS NULL OR setClass = 'work' THEN plannedWeight END) AS W
    FROM completed_set
    WHERE sessionId = ? AND deletedAt IS NULL
    GROUP BY exerciseId
    ORDER BY MIN(sortOrder) ASC`).all(sessionId);

  const plan = [];
  let runningDelta = 0;
  for (let i = 0; i < slices.length; i++) {
    const slice = slices[i];
    // BR-009: never regenerate — pair already ramped ⇒ skip.
    const already = db.prepare(`SELECT COUNT(*) AS n FROM completed_set
        WHERE sessionId = ? AND exerciseId = ? AND setClass = 'warmup' AND deletedAt IS NULL`)
        .get(sessionId, slice.exerciseId).n > 0;
    if (already) continue;
    if (!isEnabled(db, routineId, slice.exerciseId)) continue;
    const rows = derive(slice.W, barWeight, plateInventory);
    if (!rows.length) continue;
    plan.push({ exerciseId: slice.exerciseId, insertBase: slice.minSort, rows });
    runningDelta += rows.length;
  }
  if (!plan.length) return;

  // Collision-free renumber: park all rows at +totalOffset, insert derived rows
  // into vacated originals (shifting only the pair exercise's tail), normalize.
  const totalOffset = runningDelta;
  db.prepare(`UPDATE completed_set SET sortOrder = sortOrder + ?
              WHERE sessionId = ? AND deletedAt IS NULL`).run(totalOffset, sessionId);

  // Blocks sort ascending by insert position; each shift moves ALL rows (any
  // exercise) at/after the parked position so interleaved foreign rows can't
  // collide with an insertion. Later insertBases absorb prior block sizes.
  const parked = [...plan].sort((a, b) => a.insertBase - b.insertBase);
  let cumulative = 0;
  for (const entry of parked) {
    const position = entry.insertBase + totalOffset + cumulative;
    const blockShift = entry.rows.length;
    db.prepare(`UPDATE completed_set SET sortOrder = sortOrder + ?, updatedAt = ?
                WHERE sessionId = ? AND sortOrder >= ? AND deletedAt IS NULL`)
      .run(blockShift, now(), sessionId, position);
    entry.rows.forEach((row, i) => {
      db.prepare(`INSERT INTO completed_set
          (id, sessionId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration,
           actualWeight, actualReps, actualDuration, status, setClass, completedAt,
           createdAt, updatedAt, deletedAt)
        VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, 'planned', 'warmup', NULL, ?, ?, NULL)`)
        .run(uuid(), sessionId, entry.exerciseId, position + i,
             row.weight, row.reps, now(), now());
    });
    cumulative += blockShift;
  }

  // Normalize: dense 0..n-1 by current order. better-sqlite3/this SQLite build
  // doesn't evaluate the correlated scalar subquery reliably, so read the parked
  // order once and rewrite row-by-row (sessions are small; write count is O(n)).
  const parkedRows = db.prepare(`SELECT id FROM completed_set
      WHERE sessionId = ? AND deletedAt IS NULL ORDER BY sortOrder ASC`).all(sessionId);
  const norm = db.prepare(`UPDATE completed_set SET sortOrder = ? WHERE id = ?`);
  parkedRows.forEach((r, i) => norm.run(i, r.id));
}

function stampSession(db, session, sessionId) {
  const plateInventory = INVENTORIES[session.unit ?? 'kg'];
  const bar = session.bar ?? 20;
  // Seed scheme rows.
  const schemes = session.schemes ?? (session.scheme ? [session.scheme] : []);
  const setSpecs = session.blueprintSets ?? session.exercises.flatMap((ex) =>
    ex.work.map((w) => ({ exerciseId: ex.id, weight: w.weight, reps: w.reps })));
  for (const exId of new Set(setSpecs.map((s) => s.exerciseId))) insertExercise(db, exId);
  if (session.routineId) insertRoutine(db, session.routineId);
  for (const sc of schemes) if (sc) upsertScheme(db, sc);
  // Stamp work rows verbatim (SC-workout-logging §5).
  setSpecs.forEach((s, i) => insertWorkSet(db, sessionId, s.exerciseId, i, s.weight, s.reps));
  warmupApply(db, sessionId, session.routineId ?? null, bar, plateInventory);
}

function planVsActual(db, sessionId) {
  return db.prepare(`SELECT exerciseId, COALESCE(setClass, 'work') AS cls,
                            plannedWeight AS w, plannedReps AS r
                     FROM completed_set
                     WHERE sessionId = ? AND deletedAt IS NULL
                     ORDER BY sortOrder ASC`).all(sessionId);
}

function expectSessionShape(db, sessionId, expectRows, label) {
  const rows = planVsActual(db, sessionId);
  const actual = rows.map((r) => (expectRows[0] && expectRows[0].length >= 4
    ? [r.exerciseId, r.cls, r.w, r.r]
    : [r.exerciseId, r.cls, r.w]));
  const match = JSON.stringify(actual) === JSON.stringify(expectRows);
  ok(match, `${label}.session-shape (${JSON.stringify(actual)})`);
  // sortOrder contiguity (SC-foundation BR-005).
  const orders = db.prepare(`SELECT sortOrder FROM completed_set
                             WHERE sessionId = ? AND deletedAt IS NULL
                             ORDER BY sortOrder ASC`).all(sessionId).map((r) => r.sortOrder);
  const contiguous = orders.every((v, i) => v === i);
  ok(contiguous, `${label}.sortOrder-contiguous (BR-005)`);
}

// Work-class reader helpers (BR-011..BR-014 semantics; BR-015 mixed-history rule).
const workClassFilter = (db, sessionId, exerciseId) => {
  const hasWarmup = db.prepare(`SELECT COUNT(*) AS n FROM completed_set
      WHERE sessionId = ? AND exerciseId = ? AND setClass = 'warmup' AND deletedAt IS NULL`)
      .get(sessionId, exerciseId).n > 0;
  return hasWarmup
    ? `setClass = 'work'`                                   // classified session: strict
    : `(setClass IS NULL OR setClass = 'work')`;            // legacy: NULL reads as work
};

const isClean = (sets) => {
  const performed = sets.filter((s) => s.status !== 'dropped');
  if (!performed.length) return false;
  if (performed.some((s) => s.status === 'failed')) return false;
  return performed.every((s) => (s.actualReps ?? 0) >= (s.plannedReps ?? 0));
};

// BR-012 stall mirror, filtered to work rows per BR-011.
function stallStep(rec, sessionSets, previousWeight) {
  const performed = sessionSets.filter((s) => s.status !== 'dropped');
  if (!performed.length) return { banner: false, rec };
  const r = { ...rec };
  const currentW = performed[performed.length - 1].actualWeight;
  if (previousWeight != null && currentW != null && previousWeight !== currentW) {
    r.stallCount = 0; return { banner: false, rec: r };
  }
  if (isClean(performed)) { r.stallCount = 0; return { banner: false, rec: r }; }
  const fails = performed.filter((s) => s.status === 'failed');
  const F = fails.length ? Math.max(...fails.map((s) => s.actualReps ?? 0)) : null;
  const P = performed[0].plannedReps;
  if (F != null && P != null && F < P) r.stallCount += 1;
  return { banner: !r.stallMuted && r.stallCount === r.nextBannerAt, rec: r };
}

const PR_KINDS = ['max_1rm', 'max_volume', 'max_reps', 'max_duration'];

// ---------------------------------------------------------------------------
// V1 — pure ramp tables
// ---------------------------------------------------------------------------
(function v1RampTables() {
  const fx = JSON.parse(readFileSync(join(fixturesDir, '01-ramp-tables.json'), 'utf8'));
  for (const v of fx.pureUnits) {
    const inv = INVENTORIES[v.in.unit];
    const got = derive(v.in.w, v.in.bar, inv).map((r) => [r.weight, r.reps]);
    const match = JSON.stringify(got) === JSON.stringify(v.expect);
    ok(match, `01.${v.id} ramp=${JSON.stringify(got)}`);
  }
})();

// ---------------------------------------------------------------------------
// V2/V6 — gate and defaults (fresh DB per vector)
// ---------------------------------------------------------------------------
(function v2v6Gate() {
  const fx = JSON.parse(readFileSync(join(fixturesDir, '02-gate-and-defaults.json'), 'utf8'));
  for (const v of fx.materialize) {
    const db = newDb();
    const routineId = 'rt-a';
    insertRoutine(db, routineId);
    const sessionId = insertSession(db, routineId);
    let order = 0;
    for (const ex of v.exercises) {
      insertExercise(db, ex.id);
      if (v.scheme) upsertScheme(db, { routineId, exerciseId: ex.id, warmupEnabled: v.scheme.warmupEnabled });
      for (const w of ex.work) insertWorkSet(db, sessionId, ex.id, order++, w.weight, w.reps);
    }
    warmupApply(db, sessionId, routineId, 20, INVENTORIES.kg);
    expectSessionShape(db, sessionId, v.expectSession.map((r) => [r[0], r[1], r[2]]), `02.${v.id}`);
    db.close();
  }
})();

// ---------------------------------------------------------------------------
// V3/V4/V5 — ticket vectors: session materialization shapes
// ---------------------------------------------------------------------------
for (const file of ['03-two-rung-82.5.json', '04-three-rung-120.json', '05-collapse-bar-only.json']) {
  const fx = JSON.parse(readFileSync(join(fixturesDir, file), 'utf8'));
  const db = newDb();
  const session = fx.session;
  insertRoutine(db, session.routineId);
  const sessionId = insertSession(db, session.routineId);
  let order = 0;
  for (const ex of session.exercises) {
    insertExercise(db, ex.id);
    upsertScheme(db, session.scheme);
    for (const w of ex.work) insertWorkSet(db, sessionId, ex.id, order++, w.weight, w.reps);
  }
  warmupApply(db, sessionId, session.routineId, session.bar, INVENTORIES[session.unit]);
  const id = file.split('-')[0];
  expectSessionShape(db, sessionId, fx.expectSession, `${id}`);
  // Written-row shape (BR-008): warmup rows carry plannedX, NULL actuals, planned.
  const warmups = db.prepare(`SELECT * FROM completed_set
      WHERE sessionId = ? AND setClass = 'warmup' AND deletedAt IS NULL`).all(sessionId);
  const shapeOk = warmups.length > 0 && warmups.every((r) =>
    r.status === 'planned' && r.actualWeight === null && r.actualReps === null &&
    r.actualDuration === null && r.completedAt === null && r.plannedWeight !== null && r.plannedReps !== null);
  ok(shapeOk, `${id}.warmup-row-shape (BR-008; n=${warmups.length})`);
  db.close();
}

// ---------------------------------------------------------------------------
// V7 — FSM behavior + UI chip contract on written rows
// ---------------------------------------------------------------------------
(function v7Fsm() {
  const fx = JSON.parse(readFileSync(join(fixturesDir, '06-write-shape-and-fsm.json'), 'utf8'));
  const db = newDb();
  const s = fx.session;
  insertRoutine(db, s.routineId);
  const sessionId = insertSession(db, s.routineId);
  let order = 0;
  for (const ex of s.exercises) {
    insertExercise(db, ex.id);
    upsertScheme(db, s.scheme);
    for (const w of ex.work) insertWorkSet(db, sessionId, ex.id, order++, w.weight, w.reps);
  }
  warmupApply(db, sessionId, s.routineId, s.bar, INVENTORIES[s.unit]);

  const warmupRows = db.prepare(`SELECT * FROM completed_set
      WHERE sessionId = ? AND setClass = 'warmup' AND deletedAt IS NULL ORDER BY sortOrder`).all(sessionId);
  // Row-shape expectations from fixture.
  const sh = fx.expectRowShape;
  const shapeOk = warmupRows.every((r) =>
    r.setClass === sh.setClass && r.status === sh.status &&
    r.actualWeight === sh.actualWeight && r.actualReps === sh.actualReps &&
    r.actualDuration === sh.actualDuration && r.completedAt === sh.completedAt);
  ok(shapeOk, '07.row-shape (BR-008)');
  ok(sh.uiChip === 'WU' && sh.uiGrayed === true, '07.ui-chip-contract (BR-016: WU chip + grayed — renderer input)');

  for (const step of fx.fsm) {
    const row = warmupRows[step.index];
    if (step.action === 'accept') {
      // SC-workout-logging BR-001 1-tap: actualX = plannedX, status completed.
      db.prepare(`UPDATE completed_set SET status='completed', actualWeight=plannedWeight,
                  actualReps=plannedReps, completedAt=?, updatedAt=? WHERE id=?`)
        .run(now(), now(), row.id);
      const r = db.prepare(`SELECT * FROM completed_set WHERE id=?`).get(row.id);
      ok(r.status === step.expectStatus, `07.${step.id}.status`);
      ok(closeTo(r.actualWeight, step.expectActuals.actualWeight) && r.actualReps === step.expectActuals.actualReps,
         `07.${step.id}.one-tap-copies-planned (BR-017/BR-018)`);
    }
    if (step.action === 'drop') {
      db.prepare(`UPDATE completed_set SET status='dropped', updatedAt=? WHERE id=?`).run(now(), row.id);
      const r = db.prepare(`SELECT status FROM completed_set WHERE id=?`).get(row.id);
      ok(r.status === step.expectStatus, `07.${step.id}.status (BR-018 drop path)`);
    }
  }
  db.close();
})();

// ---------------------------------------------------------------------------
// V8/V9 — PR exclusion (BR-013) + volume exclusion (BR-014)
// ---------------------------------------------------------------------------
(function v8v9PrVolume() {
  const fx = JSON.parse(readFileSync(join(fixturesDir, '07-pr-and-volume.json'), 'utf8'));
  const db = newDb();
  const s = fx.session;
  insertRoutine(db, s.routineId);
  const sessionId = insertSession(db, s.routineId);
  let order = 0;
  for (const ex of s.exercises) {
    insertExercise(db, ex.id);
    upsertScheme(db, s.scheme);
    for (const w of ex.work) insertWorkSet(db, sessionId, ex.id, order++, w.weight, w.reps);
  }
  warmupApply(db, sessionId, s.routineId, s.bar, INVENTORIES[s.unit]);

  // Pre-existing PR row (kind=max_reps value 8 — warm-up bar×10 would beat it if
  // included). Post-0009 canonical shape: sessionId is required on every row.
  for (const pr of fx.preExistingPRs ?? []) {
    db.prepare(`INSERT INTO personal_record (id, exerciseId, sessionId, setId, kind, value, achievedAt, createdAt, updatedAt)
                VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?)`)
      .run(uuid(), pr.exerciseId, sessionId, pr.kind, pr.value, now(), now(), now());
  }

  // Complete every set at planned values.
  if (s.completeAllAtPlanned) {
    db.prepare(`UPDATE completed_set SET status='completed', actualWeight=plannedWeight,
                actualReps=plannedReps, completedAt=?, updatedAt=?
                WHERE sessionId=? AND deletedAt IS NULL`).run(now(), now(), sessionId);
  }

  // BR-013: PR derivation reads work-class rows only (BR-015 filter); a warm-up
  // setId must never appear on personal_record, and bar×10 must never beat max_reps.
  const workFilter = workClassFilter(db, sessionId, 'ex-bench');
  const workRows = db.prepare(`SELECT * FROM completed_set
      WHERE sessionId=? AND exerciseId='ex-bench' AND ${workFilter}
        AND status='completed' AND deletedAt IS NULL`).all(sessionId);
  if (!workRows.length) { fail('07.harness.no-completed-work-rows'); return; }
  // Mimic #26's PR writer over the work-class feed: best per kind, insert when
  // beating baseline (#26 owns the real writer; here we only prove the feed).
  const candidates = {
    max_1rm: Math.max(...workRows.map((r) => r.actualWeight ?? 0)),
    max_volume: Math.max(...workRows.map((r) => (r.actualWeight ?? 0) * (r.actualReps ?? 0))),
    max_reps: Math.max(...workRows.map((r) => r.actualReps ?? 0)),
    max_duration: Math.max(...workRows.map((r) => r.actualDuration ?? 0)),
  };
  // Under BR-013 work-class filtering these are the session's only PR-visible
  // numbers; the rep PR (8) must survive because work reps are 5, and the
  // warm-up rows (10 reps at 20 kg; 40×5; 60×3) never reach the feed.
  ok(candidates.max_reps === 5, `07.v8.work-feed-max-reps (${candidates.max_reps}; warm-up 10 excluded)`);
  ok(candidates.max_1rm === 82.5, `07.v8.work-feed-max-1rm (${candidates.max_1rm})`);
  const repPr = db.prepare(`SELECT value FROM personal_record WHERE exerciseId='ex-bench' AND kind='max_reps'`).get();
  ok(repPr.value === 8, '07.v8.rep-pr-still-8 (bar×10 never writes max_reps)');
  // No personal_record row points at any warm-up set (would-be writers only see work ids).
  const prWithWarmupSet = db.prepare(`
      SELECT COUNT(*) AS n FROM personal_record pr
      JOIN completed_set cs ON cs.id = pr.setId
      WHERE cs.setClass = 'warmup'`).get().n;
  ok(prWithWarmupSet === 0, `07.v8.no-pr-references-warmup-set (BR-013; n=${prWithWarmupSet})`);

  // BR-014: tonnage excludes warm-up rows.
  const all = db.prepare(`SELECT SUM(actualWeight*actualReps) AS v FROM completed_set
      WHERE sessionId=? AND status='completed' AND deletedAt IS NULL`).get(sessionId).v;
  const work = db.prepare(`SELECT SUM(actualWeight*actualReps) AS v FROM completed_set
      WHERE sessionId=? AND status='completed' AND deletedAt IS NULL AND (setClass IS NULL OR setClass='work')`)
      .get(sessionId).v;
  ok(closeTo(work, fx.expect.workOnlyVolume), `07.v9.work-volume (${work})`);
  ok(closeTo(all, fx.expect.allRowsVolume), `07.v9.all-rows-volume (${all})`);
  ok(closeTo(all - work, fx.expect.allRowsVolume - fx.expect.workOnlyVolume),
     '07.v9.warmup-excluded-delta (BR-014 supersedes SC-foundation INV-6 volume line)');
  db.close();
})();

// ---------------------------------------------------------------------------
// V10/V11 — stall immunity, clean predicate, immutability
// ---------------------------------------------------------------------------
(function v10v11Stall() {
  const fx = JSON.parse(readFileSync(join(fixturesDir, '08-stall-clean-immutable.json'), 'utf8'));
  for (const v of fx.stall) {
    const db = newDb();
    insertExercise(db, 'ex-bench');
    const sessionId = insertSession(db, null);
    v.session.forEach((s, i) => {
      db.prepare(`INSERT INTO completed_set
          (id, sessionId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration,
           actualWeight, actualReps, actualDuration, status, setClass, completedAt,
           createdAt, updatedAt, deletedAt)
        VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, NULL, ?, ?, ?, ?, ?, NULL)`)
        .run(uuid(), sessionId, s.exerciseId, i, s.plannedWeight, s.plannedReps,
             s.actualWeight, s.actualReps, s.status, s.setClass, now(), now(), now());
    });
    const workFilter = workClassFilter(db, sessionId, 'ex-bench');
    const workRows = db.prepare(`SELECT * FROM completed_set
        WHERE sessionId=? AND exerciseId='ex-bench' AND ${workFilter} AND deletedAt IS NULL
        ORDER BY sortOrder ASC`).all(sessionId);
    ok(isClean(workRows) === v.expect.clean, `08.${v.id}.clean (BR-012/BR-011)`);

    let rec = { stallCount: v.stallCountBefore, stallMuted: 0, nextBannerAt: 3 };
    const repeats = v.repeat ?? 1;
    let bannerSeen = false;
    for (let n = 0; n < repeats; n++) {
      const r = stallStep(rec, workRows, v.previousWeight ?? null);
      rec = r.rec; bannerSeen = bannerSeen || r.banner;
    }
    ok(rec.stallCount === v.expect.stallCountAfter,
       `08.${v.id}.stallCount (BR-011; got ${rec.stallCount})`);
    ok(bannerSeen === v.expect.banner, `08.${v.id}.banner`);
    db.close();
  }

  // BR-009 double-apply.
  const da = fx.doubleApply.session;
  const db = newDb();
  insertRoutine(db, da.routineId);
  const sessionId = insertSession(db, da.routineId);
  let order = 0;
  for (const ex of da.exercises) {
    insertExercise(db, ex.id);
    upsertScheme(db, da.scheme);
    for (const w of ex.work) insertWorkSet(db, sessionId, ex.id, order++, w.weight, w.reps);
  }
  warmupApply(db, sessionId, da.routineId, da.bar, INVENTORIES[da.unit]);
  const after1 = db.prepare(`SELECT COUNT(*) AS n FROM completed_set WHERE sessionId=? AND deletedAt IS NULL`).get(sessionId).n;
  warmupApply(db, sessionId, da.routineId, da.bar, INVENTORIES[da.unit]);
  const after2 = db.prepare(`SELECT COUNT(*) AS n FROM completed_set WHERE sessionId=? AND deletedAt IS NULL`).get(sessionId).n;
  ok(after2 === fx.doubleApply.expectRowCountAfterSecondApply && after1 === after2,
     `08.v11.double-apply-noop (BR-009; ${after1}->${after2})`);
  db.close();
})();

// ---------------------------------------------------------------------------
// V12 — interleave + renumber
// ---------------------------------------------------------------------------
(function v12Interleave() {
  const fx = JSON.parse(readFileSync(join(fixturesDir, '09-interleave-renumber.json'), 'utf8'));
  const db = newDb();
  const s = fx.session;
  for (const ex of new Set(s.blueprintSets.map((x) => x.exerciseId))) insertExercise(db, ex);
  insertRoutine(db, s.routineId);
  const sessionId = insertSession(db, s.routineId);
  for (const sc of s.schemes) upsertScheme(db, sc);
  s.blueprintSets.forEach((x, i) => insertWorkSet(db, sessionId, x.exerciseId, i, x.weight, x.reps));
  warmupApply(db, sessionId, s.routineId, s.bar, INVENTORIES[s.unit]);
  expectSessionShape(db, sessionId, fx.expectSession, '09.v12-interleave-renumber');
  db.close();
})();

// ---------------------------------------------------------------------------
// Migration 0010 scaffold checks
// ---------------------------------------------------------------------------
(function migration0010() {
  const db = newDb();
  const t = db.prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name='warmup_contract_scaffold'`).get();
  ok(!!t, 'migration.0010.scaffold-table-exists');
  const marker = db.prepare(`SELECT * FROM warmup_contract_scaffold WHERE id='sc-warmup-1.0.0-shape-check'`).get();
  ok(!!marker, 'migration.0010.shape-assertion-marker (setClass+warmupEnabled confirmed present)');
  const cols = db.prepare(`PRAGMA table_info(progression_scheme)`).all().map((c) => c.name);
  ok(cols.includes('warmupEnabled'), 'migration.0010.warmupEnabled-present (BR-010 default OFF)');
  db.close();
})();

if (failures === 0) { console.log(`\nALL WARMUP FIXTURES PASS (${passes} checks)`); process.exit(0); }
console.error(`\n${failures} check(s) failed (${passes} passed)`); process.exit(1);
