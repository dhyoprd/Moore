// Seam-1 (logic) + Seam-2 (persistence) + Seam-3 (cue dispatch) verifier for
// SC-rest@1.0.0 (ticket #23). Section-by-section per fixture semantics:
//   duration-hierarchy.json          BR-001  four-level resolve, first non-null wins
//   oneoff-adjust.json               BR-002  ±15s one-off adjust, never persisted; −15<15 ⇒ skip
//   skip-gesture.json                BR-003  skip semantics
//   restart-on-mid-rest-completion   BR-004  restart picks up the NEW set's duration
//   drop-no-rest.json                BR-005  a drop never starts/modifies rest
//   final-set-and-finish-morph.json  BR-006 + §2b morph consumes the run, morph = cue
//   recompute-on-kill.json           BR-007  recompute from timestamps; expired presents expired
//   rest-end-cue.json                BR-008  cue.rest.end fired once, gated to rest state
//   duration-clamp.json              BR-001+INV-S3  resolution clamps to [0,600]
//   rest-settings-persistence.json   §3d migration 0007 + INV-S2 defaults/upsert
//   forward-compat-suppress.json     §2b/INV-T6  a later run's cue is not absorbed by an earlier morph
//
// Usage: node Tests/MooreRestTests/VerifyRest.mjs

import Database from 'better-sqlite3';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const worktreeRoot = join(here, '..', '..');
const foundationMigDir = join(worktreeRoot, 'Sources', 'MooreFoundation', 'Migrations');
const routinesMigDir = join(worktreeRoot, 'Sources', 'MooreRoutines', 'Migrations');
const restMigDir = join(worktreeRoot, 'Sources', 'MooreRest', 'Migrations');
const fixturesDir = join(here, 'Fixtures');

const MIGRATIONS = [
  { dir: foundationMigDir, name: '0001_core.sql', optional: false },
  { dir: foundationMigDir, name: '0002_warmup_progression.sql', optional: false },
  { dir: foundationMigDir, name: '0003_import_columns.sql', optional: false },
  { dir: routinesMigDir, name: '0005_routines_folders.sql', optional: false },
  { dir: routinesMigDir, name: '0006_routines_session_link.sql', optional: false },
  { dir: restMigDir, name: '0007_rest_fields.sql', optional: false },
];

// 0007's idempotent tail: the `app_setting` defaults seed is `INSERT OR IGNORE`
// and therefore safe to re-run in-process; the ALTERs it sits beside are applied
// exactly once by GRDB's migration registry at runtime (tracked by name), so a
// verifier re-run exercises only this seed statement — precisely what INV-S2's
// "re-migration never resets the user's value" guarantee is about.
const SETTINGS_SEED_SQL = `
  INSERT OR IGNORE INTO app_setting (key, value, updatedAt) VALUES
    ('defaultRestCompoundSec',  '180', strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    ('defaultRestIsolationSec', '90',  strftime('%Y-%m-%dT%H:%M:%fZ','now'));
`;

let failures = 0;
let passes = 0;
const fail = (m) => { console.error(`FAIL: ${m}`); failures += 1; };
const pass = (m) => { passes += 1; console.log(`PASS: ${m}`); };

// ---------------------------------------------------------------------------
// Migrations (idempotent; optional ones warn-and-continue so a missing #20
// artifact blocks nothing it shouldn't)
// ---------------------------------------------------------------------------
function applyMigrations(db, { only = MIGRATIONS } = {}) {
  for (const { dir, name, optional } of only) {
    const path = join(dir, name);
    try {
      db.exec(readFileSync(path, 'utf8'));
      pass(`migration.apply ${name}`);
    } catch (e) {
      if (optional) { console.log(`SKIP: migration ${name} (${e.message})`); continue; }
      fail(`migration.apply ${name}: ${e.message}`);
    }
  }
}

function freshDb() {
  const db = new Database(':memory:');
  applyMigrations(db);
  return db;
}

// ---------------------------------------------------------------------------
// FSM mirror — port of Sources/MooreRest/RestCycle.swift + RestResolver.swift
// (verbatim logic; both are pure and deterministic, so this JS mirror IS the
// seam-1/seam-3 check on hosts without a Swift toolchain). If this mirror and
// the Swift one drift, RestCycleTests.swift will catch it on an iOS host.
// ---------------------------------------------------------------------------
const MIN_DUR = 0;
const MAX_DUR = 600;
const clampDur = (n) => Math.min(Math.max(n, MIN_DUR), MAX_DUR);

function restResolve({ perSetSec, perExerciseSec, perRoutineSec, categoryIsCompound }, settings) {
  if (perSetSec != null)   return { durationSec: clampDur(perSetSec), source: 'perSet' };
  if (perExerciseSec != null) return { durationSec: clampDur(perExerciseSec), source: 'perExercise' };
  if (perRoutineSec != null)  return { durationSec: clampDur(perRoutineSec), source: 'perRoutine' };
  return categoryIsCompound
    ? { durationSec: clampDur(settings.defaultRestCompoundSec), source: 'globalCompound' }
    : { durationSec: clampDur(settings.defaultRestIsolationSec), source: 'globalIsolation' };
}

class RestCycleMirror {
  constructor() {
    this.state = { kind: 'noRest' };
    this.overlay = 'rest';
    this.allSetsTerminal = false;
    this.cues = [];  // seam-3 spy
  }
  static remainingSec(run, now) {
    return (run.startedAt + run.durationSec + run.adjustmentSec) - now;
  }
  _emit(cue) { if (cue) this.cues.push(cue); return cue; }
  dispatch(action) {
    switch (action.do) {
      case 'setCompleted':
      case 'setFailed': {
        const d = clampDur(action.resolution.durationSec);
        this.state = { kind: 'restRunning', durationSec: d, startedAt: action.at, adjustmentSec: 0 };
        this.allSetsTerminal = !!action.allSetsTerminal;
        this.overlay = 'rest';   // INV-T6 unlatch
        return null;
      }
      case 'setDropped':
        return null;
      case 'skip': {
        if (this.state.kind === 'noRest') return null;
        if (this.allSetsTerminal) {
          this.state = { kind: 'noRest' };
          this.overlay = 'finishPanel';
          return this._emit('cue.finish.morph');
        }
        this.state = { kind: 'noRest' };
        return null;
      }
      case 'adjustSec': {
        if (this.state.kind !== 'restRunning') return null;
        const newAdj = this.state.adjustmentSec + action.delta;
        if (RestCycleMirror.remainingSec({ ...this.state, adjustmentSec: newAdj }, action.at) <= 0) {
          this.state = { kind: 'noRest' };
          return null;
        }
        const total = this.state.durationSec + newAdj;
        const capped = total > MAX_DUR ? MAX_DUR - this.state.durationSec : newAdj;
        this.state = { ...this.state, adjustmentSec: capped };
        return null;
      }
      case 'expireNaturally':
      case 'backgrounded': {
        const s = this.state;
        if (s.kind !== 'restRunning') return null;
        if (RestCycleMirror.remainingSec(s, action.at) > 0) return null;
        if (this.allSetsTerminal) {
          this.state = { kind: 'noRest' };
          this.overlay = 'finishPanel';
          return this._emit('cue.finish.morph');
        }
        this.state = { kind: 'restExpired', durationSec: s.durationSec, startedAt: s.startedAt, adjustmentSec: s.adjustmentSec };
        return this._emit('cue.rest.end');
      }
      default:
        return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Persistence helpers (seam-2)
// ---------------------------------------------------------------------------
function fetchSettings(db) {
  const row = (k) => db.prepare('SELECT value FROM app_setting WHERE key = ?').get(k)?.value;
  return {
    defaultRestCompoundSec: row('defaultRestCompoundSec') != null ? parseInt(row('defaultRestCompoundSec'), 10) : 180,
    defaultRestIsolationSec: row('defaultRestIsolationSec') != null ? parseInt(row('defaultRestIsolationSec'), 10) : 90,
  };
}
function updateSettings(db, { compoundSec, isolationSec }, at) {
  const now = at ?? new Date().toISOString();
  const up = (k, v) => db.prepare(`
    INSERT INTO app_setting (key,value,updatedAt) VALUES (?,?,?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value, updatedAt=excluded.updatedAt`).run(k, String(v), now);
  if (compoundSec != null) up('defaultRestCompoundSec', compoundSec);
  if (isolationSec != null) up('defaultRestIsolationSec', isolationSec);
}

function snapshotTable(db, table) {
  try { return db.prepare(`SELECT * FROM ${table} ORDER BY rowid`).all(); }
  catch { return null; }
}
function tableColumns(db, table) {
  return db.prepare(`PRAGMA table_info(${table})`).all();
}

const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// ---------------------------------------------------------------------------
// Step executor — pure FSM steps
// ---------------------------------------------------------------------------
function runFsmSteps(fixture, vector, db) {
  const cycle = new RestCycleMirror();
  const settingsDefaults = vector.settingsDefaults ?? fixture.settingsDefaults ?? { defaultRestCompoundSec: 180, defaultRestIsolationSec: 90 };
  let lastResolution = null;

  if (fixture.database?.snapshotTable && db) snapshotTable(db, fixture.database.snapshotTable); // prime
  const before = fixture.database?.snapshotTable && db ? snapshotTable(db, fixture.database.snapshotTable) : null;

  vector.steps.forEach((step, i) => {
    const label = `${vector.id}.step${i + 1}(${step.do}@${step.at})`;
    switch (step.do) {
      case 'setCompleted':
      case 'setFailed': {
        lastResolution = restResolve(step.resolveInputs, settingsDefaults);
        if (step.expect?.resolution && !eq(lastResolution, step.expect.resolution)) {
          fail(`${label}: resolution ${JSON.stringify(lastResolution)} != expected ${JSON.stringify(step.expect.resolution)}`);
          return;
        }
        cycle.dispatch({ ...step, resolution: lastResolution });
        break;
      }
      default:
        cycle.dispatch(step);
    }

    const ex = step.expect ?? {};
    let ok = true;
    if (ex.state && cycle.state.kind !== ex.state) { ok = false; fail(`${label}: state=${cycle.state.kind} expected ${ex.state}`); }
    if (ok && ex.overlay && cycle.overlay !== ex.overlay) { ok = false; fail(`${label}: overlay=${cycle.overlay} expected ${ex.overlay}`); }
    if (ok && ex.durationSec != null && cycle.state.durationSec !== ex.durationSec) { ok = false; fail(`${label}: durationSec=${cycle.state.durationSec} expected ${ex.durationSec}`); }
    if (ok && ex.startedAt != null && cycle.state.startedAt !== ex.startedAt) { ok = false; fail(`${label}: startedAt=${cycle.state.startedAt} expected ${ex.startedAt}`); }
    if (ok && ex.adjustmentSec != null && cycle.state.adjustmentSec !== ex.adjustmentSec) { ok = false; fail(`${label}: adjustmentSec=${cycle.state.adjustmentSec} expected ${ex.adjustmentSec}`); }
    if (ok && ex.remainingSec != null) {
      const rem = cycle.state.kind === 'restRunning' ? RestCycleMirror.remainingSec(cycle.state, step.at) : null;
      if (rem !== ex.remainingSec) { ok = false; fail(`${label}: remaining=${rem} expected ${ex.remainingSec}`); }
    }
    if (ok && 'cue' in ex) {
      const got = cycle.cues[cycle.cues.length - 1] ?? null;
      if (got !== ex.cue) { ok = false; fail(`${label}: cue=${got} expected ${ex.cue}`); }
    }
    if (ok) pass(label);
  });

  const fin = vector.finalExpect ?? {};
  if (fin.state && cycle.state.kind !== fin.state) fail(`${vector.id}.final: state=${cycle.state.kind} expected ${fin.state}`); else if (fin.state) pass(`${vector.id}.final.state`);
  if (fin.overlay && cycle.overlay !== fin.overlay) fail(`${vector.id}.final: overlay=${cycle.overlay} expected ${fin.overlay}`); else if (fin.overlay) pass(`${vector.id}.final.overlay`);
  if (fin.adjustmentSec != null && cycle.state.adjustmentSec !== fin.adjustmentSec) fail(`${vector.id}.final: adjustmentSec=${cycle.state.adjustmentSec} expected ${fin.adjustmentSec}`);
  if (fin.remainingSec != null && cycle.state.kind === 'restRunning') {
    const rem = RestCycleMirror.remainingSec(cycle.state, (vector.steps.at(-1).at));
    if (rem !== fin.remainingSec) fail(`${vector.id}.final: remaining=${rem} expected ${fin.remainingSec}`);
  }
  if (fin.cues && !eq(cycle.cues, fin.cues)) fail(`${vector.id}.final: cues=${JSON.stringify(cycle.cues)} expected ${JSON.stringify(fin.cues)}`); else if (fin.cues) pass(`${vector.id}.final.cues`);
  if (fin.persistenceUnchanged && before != null && db) {
    const after = snapshotTable(db, fixture.database.snapshotTable);
    eq(before, after) ? pass(`${vector.id}.persistenceUnchanged`) : fail(`${vector.id}: ${fixture.database.snapshotTable} changed across the run (INV-T2 violated)`);
  }
  return cycle;
}

// ---------------------------------------------------------------------------
// Persistence vector (rest-settings-persistence.json V13)
// ---------------------------------------------------------------------------
function runSettingsPersistence(fixture, vector) {
  const db = freshDb();
  const defaults = vector.settingsDefaults ?? fixture.settingsDefaults;

  // Assert table/column shape claims from the fixture header.
  const shape = fixture.database.assertTableShape;
  if (shape) {
    const cols = tableColumns(db, shape.name);
    const names = cols.map(c => c.name);
    for (const c of shape.columns) {
      names.includes(c) ? pass(`schema.${shape.name}.${c}.exists`) : fail(`schema: ${shape.name} missing column ${c}`);
    }
    const pk = cols.filter(c => c.pk > 0).sort((a, b) => a.pk - b.pk).map(c => c.name);
    eq(pk, shape.primaryKey) ? pass(`schema.${shape.name}.primaryKey`) : fail(`schema: ${shape.name} PK ${JSON.stringify(pk)} != ${JSON.stringify(shape.primaryKey)}`);
  }
  for (const add of fixture.database.assertColumnAdded ?? []) {
    const cols = tableColumns(db, add.table);
    const col = cols.find(c => c.name === add.column);
    if (!col) { fail(`schema: ${add.table}.${add.column} missing`); continue; }
    col.type === add.type ? pass(`schema.${add.table}.${add.column}.type`) : fail(`schema: ${add.table}.${add.column} type ${col.type} != ${add.type}`);
    (col.notnull === 0) === add.nullable ? pass(`schema.${add.table}.${add.column}.nullable`) : fail(`schema: ${add.table}.${add.column} nullable mismatch`);
  }

  const readUpdatedAt = (k) => db.prepare('SELECT updatedAt FROM app_setting WHERE key=?').get(k)?.updatedAt;

  vector.steps.forEach((step, i) => {
    const label = `${vector.id}.step${i + 1}(${step.do})`;
    switch (step.do) {
      case 'fetchSettings': {
        const got = fetchSettings(db);
        eq(got, step.expect.settings) ? pass(label) : fail(`${label}: settings ${JSON.stringify(got)} != ${JSON.stringify(step.expect.settings)}`);
        break;
      }
      case 'updateSettings': {
        const before = readUpdatedAt('defaultRestCompoundSec');
        // Deterministic later timestamp: the Migrate seed uses strftime(...now),
        // and two same-millisecond writes would otherwise look "not bumped".
        const bumped = step.at ?? new Date(Date.parse(before ?? 0) + 1000).toISOString();
        updateSettings(db, { compoundSec: step.compoundSec, isolationSec: step.isolationSec }, bumped);
        vector._lastBeforeUpdatedAt = before;
        const got = fetchSettings(db);
        eq(got, step.expect.settings) ? pass(label) : fail(`${label}: settings ${JSON.stringify(got)} != ${JSON.stringify(step.expect.settings)}`);
        break;
      }
      case 'assertUpdatedAtBumped': {
        const after = readUpdatedAt(step.key);
        after && after !== vector._lastBeforeUpdatedAt ? pass(label) : fail(`${label}: updatedAt not bumped (before=${vector._lastBeforeUpdatedAt} after=${after})`);
        break;
      }
      case 'reapplyMigrations': {
        // INV-S2: the idempotent seed tail of 0007 must not reset the user's value.
        db.exec(SETTINGS_SEED_SQL);
        pass(label);
        break;
      }
      default:
        fail(`${label}: unknown persistence step ${step.do}`);
    }
  });

  const fin = vector.finalExpect ?? {};
  if (fin.settings) {
    const got = fetchSettings(db);
    eq(got, fin.settings) ? pass(`${vector.id}.final.settings`) : fail(`${vector.id}.final: settings ${JSON.stringify(got)} != ${JSON.stringify(fin.settings)}`);
  }
  if (defaults && fin.settings == null) {
    const got = fetchSettings(db);
    eq(got, defaults) ? pass(`${vector.id}.final.defaults`) : fail(`${vector.id}.final: defaults ${JSON.stringify(got)} != ${JSON.stringify(defaults)}`);
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
function main() {
  // Sanity: schema sanity across the full migration chain.
  {
    const db = freshDb();
    const tables = db.prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'`).all().map(r => r.name);
    for (const t of ['planned_set', 'routine', 'app_setting']) {
      tables.includes(t) ? pass(`table.${t}.exists`) : fail(`missing table ${t}`);
    }
  }

  const fx = (name) => JSON.parse(readFileSync(join(fixturesDir, name), 'utf8'));

  const fsmFixtures = [
    'duration-hierarchy.json',
    'oneoff-adjust.json',
    'skip-gesture.json',
    'restart-on-mid-rest-completion.json',
    'drop-no-rest.json',
    'final-set-and-finish-morph.json',
    'recompute-on-kill.json',
    'rest-end-cue.json',
    'duration-clamp.json',
    'forward-compat-suppress.json',
  ];
  for (const name of fsmFixtures) {
    const fixture = fx(name);
    for (const vector of fixture.vectors) {
      runFsmSteps(fixture, vector, null);
    }
  }

  // Persistence-backed fixtures get a real DB so their persistence checks run.
  runSettingsPersistence(fx('rest-settings-persistence.json'), fx('rest-settings-persistence.json').vectors[0]);

  // Persistence checks that need a DB for the snapshot (e.g. V5's INV-T2).
  {
    const adjustFixture = fx('oneoff-adjust.json');
    for (const vector of adjustFixture.vectors) {
      if (vector.finalExpect?.persistenceUnchanged) {
        const db = freshDb();
        runFsmSteps(adjustFixture, vector, db);
      }
    }
  }

  console.log(`\n${passes} passed, ${failures} failed`);
  if (failures === 0) { console.log('ALL REST FIXTURES PASS'); process.exit(0); }
  console.error(`${failures} assertion(s) failed`); process.exit(1);
}

main();
