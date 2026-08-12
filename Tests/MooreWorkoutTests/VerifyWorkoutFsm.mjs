// Seam-1/2 verifier for SC-workout-logging@1.0.0 (ticket #22).
// Per-fixture fresh in-memory DB (migrations 0001–0006). Each fixture runs its
// action list through a JS mirror of WorkoutSessionFSM's rules and asserts both
// the resulting DB rows and the derived StateSnapshot fields.
//
// Usage: node Tests/MooreWorkoutTests/VerifyWorkoutFsm.mjs

import Database from 'better-sqlite3';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const worktreeRoot = join(here, '..', '..');
const fixturesDir = join(here, 'Fixtures');

const MIGRATIONS = [
  ['MooreFoundation', '0001_core.sql'],
  ['MooreFoundation', '0002_warmup_progression.sql'],
  ['MooreFoundation', '0003_import_columns.sql'],
  ['MooreRoutines', '0005_routines_folders.sql'],
  ['MooreRoutines', '0006_routines_session_link.sql'],
];

let failures = 0;
const fail = (m) => { console.error(`FAIL: ${m}`); failures += 1; };
const pass = (m) => console.log(`PASS: ${m}`);
const uuid = () => crypto.randomUUID();
const now = () => new Date().toISOString();

function applyMigrations(db) {
  for (const [module, name] of MIGRATIONS) {
    db.exec(readFileSync(join(worktreeRoot, 'Sources', module, 'Migrations', name), 'utf8'));
  }
}

// ---------------------------------------------------------------------------
// JS mirror of WorkoutSessionFSM (Sources/MooreWorkout/WorkoutSessionFSM.swift).
// Kept deliberately close to the Swift struct: same guards, same cue rules,
// same INV-W4 exactly-once finish morph, same BR-003 undo-window semantics.
// ---------------------------------------------------------------------------
class FsmMirror {
  constructor(sessionId, sets) {
    this.sessionId = sessionId;
    this.sets = sets; // [{ id, exerciseId, sortOrder, status, plannedWeight, ... }]
    this.overlayState = 'idle';
    this.restRequested = false;
    this.lastCompletedSetId = null;
    this.undoableDrop = null; // { setId, available }
    this.finishRequested = false;
    this.finishMorphEmitted = false;
    this.finishedAt = null;
    this.cues = [];
    this.derive();
  }
  derive() {
    this.nextIncompleteSetId = (this.sets.find(s => s.status === 'planned') || {}).id ?? null;
    this.finishReady = this.sets.length > 0 && this.sets.every(s => s.status !== 'planned');
  }
  set(i) { return this.sets[i]; }

  _terminal(i, applyActuals) {
    const s = this.sets[i];
    if (!s || s.status !== 'planned') return { ok: false };
    applyActuals(s);
    s.completedAt = now();
    if (this.undoableDrop) this.undoableDrop.available = false; // BR-003
    this.lastCompletedSetId = s.id;
    if (s.status === 'completed') this.cues.push('cue.set.completed');
    if (s.status === 'failed') this.cues.push('cue.set.failed');
    this.derive();
    if (this.finishReady) {
      this.overlayState = 'finishRequested';
      this.finishRequested = true;
      this.restRequested = false;
      if (!this.finishMorphEmitted) { this.cues.push('cue.finish.morph'); this.finishMorphEmitted = true; } // INV-W4
    } else {
      this.overlayState = 'restRequested';
      this.restRequested = true;
    }
    return { ok: true };
  }

  accept(i) {
    return this._terminal(i, (s) => {
      s.status = 'completed';
      s.actualWeight = s.plannedWeight;      // BR-001 field-copy
      s.actualReps = s.plannedReps;
      s.actualDuration = s.plannedDuration;
    });
  }
  editAndAccept(i, w, r, d) {
    return this._terminal(i, (s) => {
      s.status = 'completed';
      s.actualWeight = w; s.actualReps = r; s.actualDuration = d ?? null;
    });
  }
  fail(i, w, r, d) {
    return this._terminal(i, (s) => {
      s.status = 'failed';                    // BR-002 actuals recorded
      s.actualWeight = w; s.actualReps = r; s.actualDuration = d ?? null;
    });
  }
  editCompleted(i, w, r, d) {
    const s = this.sets[i];
    if (!s || s.status !== 'completed') return { ok: false };
    s.actualWeight = w; s.actualReps = r; s.actualDuration = d ?? null;
    // BR-006: no rest request, no cue re-emission, completedAt untouched (INV-W6).
    return { ok: true };
  }
  drop(i) {
    const s = this.sets[i];
    if (!s || s.status !== 'planned') return { ok: false };
    s.status = 'dropped';
    this.restRequested = false;               // dropped never requests rest (INV-W5)
    this.lastCompletedSetId = null;
    this.undoableDrop = { setId: s.id, available: true };
    this.cues.push('cue.set.dropped');
    this.derive();
    if (this.finishReady) {
      this.overlayState = 'finishRequested';
      this.finishRequested = true;
      if (!this.finishMorphEmitted) { this.cues.push('cue.finish.morph'); this.finishMorphEmitted = true; }
    } else {
      this.overlayState = 'idle';
    }
    return { ok: true };
  }
  undoDrop(i) {
    const s = this.sets[i];
    if (!s || s.status !== 'dropped') return { ok: false };
    if (!this.undoableDrop || this.undoableDrop.setId !== s.id || !this.undoableDrop.available) return { ok: false };
    s.status = 'planned';
    this.undoableDrop = null;
    this.restRequested = false;
    this.finishRequested = false;
    this.overlayState = 'idle';
    this.derive();
    return { ok: true };
  }
  addSet(exerciseId) {
    const t = [...this.sets].reverse().find(s => s.exerciseId === exerciseId);
    if (!t) return { ok: false };
    this.sets.push({
      id: uuid(), exerciseId, sortOrder: this.sets.length, status: 'planned',
      plannedWeight: t.plannedWeight, plannedReps: t.plannedReps, plannedDuration: t.plannedDuration,
      setClass: t.setClass ?? 'work',
      actualWeight: null, actualReps: null, actualDuration: null, completedAt: null,
    });
    if (this.finishRequested) { this.finishRequested = false; this.overlayState = 'idle'; }
    this.derive();
    return { ok: true };
  }
  finishSession() {
    if (this.finishedAt) return { ok: false };
    if (!this.finishReady) return { ok: false };
    this.finishedAt = now();
    this.overlayState = 'finishRequested';
    this.finishRequested = true;
    this.restRequested = false;
    return { ok: true };
  }
}

// ---------------------------------------------------------------------------
// DB helpers: persist the mirror's transitions the way WorkoutSessionDAO does.
// ---------------------------------------------------------------------------
function materialize(db, fixture) {
  const ts = now();
  for (const e of fixture.exercises) {
    db.prepare(`INSERT INTO exercise (id, name, exerciseType, isCustom, createdAt, updatedAt)
                VALUES (?, ?, 'strength', 0, ?, ?)`).run(e.id, e.name, ts, ts);
  }
  const r = fixture.routine;
  db.prepare(`INSERT INTO routine (id, name, sortOrder, createdAt, updatedAt) VALUES (?, ?, 0, ?, ?)`)
    .run(r.id, r.name, ts, ts);
  r.sets.forEach((s, i) => {
    db.prepare(`INSERT INTO planned_set (id, routineId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration, setClass, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(uuid(), r.id, s.exerciseId, i, s.plannedWeight, s.plannedReps, s.plannedDuration, s.setClass, ts, ts);
  });
  // Materialize.swift's copy (plannedX verbatim, actualX NULL, status planned).
  const sessionId = uuid();
  db.prepare(`INSERT INTO workout_session (id, routineId, startedAt, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?)`)
    .run(sessionId, r.id, ts, ts, ts);
  const planned = db.prepare(`SELECT * FROM planned_set WHERE routineId = ? AND deletedAt IS NULL ORDER BY sortOrder`).all(r.id);
  const setIds = [];
  planned.forEach((p, i) => {
    const id = uuid();
    setIds.push(id);
    db.prepare(`INSERT INTO completed_set (id, sessionId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration, actualWeight, actualReps, actualDuration, status, setClass, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 'planned', ?, ?, ?)`)
      .run(id, sessionId, p.exerciseId, i, p.plannedWeight, p.plannedReps, p.plannedDuration, p.setClass, ts, ts);
  });
  return { sessionId, setIds };
}

function persistTerminal(db, setId, mirrorSet) {
  db.prepare(`UPDATE completed_set SET status = ?, actualWeight = ?, actualReps = ?, actualDuration = ?, completedAt = ?, updatedAt = ? WHERE id = ?`)
    .run(mirrorSet.status, mirrorSet.actualWeight, mirrorSet.actualReps, mirrorSet.actualDuration ?? null, mirrorSet.completedAt, now(), setId);
}
function persistDrop(db, setId) {
  db.prepare(`UPDATE completed_set SET status = 'dropped', updatedAt = ? WHERE id = ?`).run(now(), setId);
}
function persistUndo(db, setId) {
  db.prepare(`UPDATE completed_set SET status = 'planned', updatedAt = ? WHERE id = ?`).run(now(), setId);
}
function persistAddSet(db, sessionId, mirrorSet) {
  db.prepare(`INSERT INTO completed_set (id, sessionId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration, actualWeight, actualReps, actualDuration, status, setClass, createdAt, updatedAt)
              VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 'planned', ?, ?, ?)`)
    .run(mirrorSet.id, sessionId, mirrorSet.exerciseId, mirrorSet.sortOrder, mirrorSet.plannedWeight, mirrorSet.plannedReps, mirrorSet.plannedDuration, mirrorSet.setClass, now(), now());
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------
function runFixture(name) {
  const fixture = JSON.parse(readFileSync(join(fixturesDir, name), 'utf8'));
  const db = new Database(':memory:');
  applyMigrations(db);

  let sessionId = null, setIds = [], fsm = null;
  const tag = `[${name}]`;

  for (const action of fixture.actions) {
    if (action.type === 'materialize') {
      ({ sessionId, setIds } = materialize(db, fixture));
      const rows = db.prepare(`SELECT * FROM completed_set WHERE sessionId = ? ORDER BY sortOrder`).all(sessionId);
      fsm = new FsmMirror(sessionId, rows.map(r => ({ ...r })));
      continue;
    }
    const i = action.setIndex;
    let res;
    switch (action.type) {
      case 'accept':
        res = fsm.accept(i);
        if (res.ok) persistTerminal(db, setIds[i], fsm.set(i));
        break;
      case 'fail':
        res = fsm.fail(i, action.actualWeight, action.actualReps, action.actualDuration ?? null);
        if (res.ok) persistTerminal(db, setIds[i], fsm.set(i));
        break;
      case 'editCompleted':
        res = fsm.editCompleted(i, action.actualWeight, action.actualReps, action.actualDuration ?? null);
        if (res.ok) persistTerminal(db, setIds[i], fsm.set(i));
        break;
      case 'drop':
        res = fsm.drop(i);
        if (res.ok) persistDrop(db, setIds[i]);
        break;
      case 'undoDrop':
        res = fsm.undoDrop(i);
        if (action.expectFailure) {
          res.ok === false ? pass(`${tag} undoDrop refused (window closed)`) : fail(`${tag} undoDrop should have been refused`);
        } else if (res.ok) {
          persistUndo(db, setIds[i]);
        } else {
          fail(`${tag} undoDrop unexpectedly refused`);
        }
        break;
      case 'addSet': {
        res = fsm.addSet(action.exerciseId);
        if (res.ok) {
          persistAddSet(db, sessionId, fsm.sets[fsm.sets.length - 1]);
          setIds.push(fsm.sets[fsm.sets.length - 1].id);
        }
        break;
      }
      case 'finishSession':
        res = fsm.finishSession();
        if (res.ok) {
          db.prepare(`UPDATE workout_session SET endedAt = ?, updatedAt = ? WHERE id = ?`).run(fsm.finishedAt, now(), sessionId);
        }
        break;
      default:
        fail(`${tag} unknown action ${action.type}`);
    }
  }

  // ---- DB assertions ----
  const exp = fixture.expect;
  const rows = db.prepare(`SELECT * FROM completed_set WHERE sessionId = ? ORDER BY sortOrder`).all(sessionId);
  rows.length === exp.setCount
    ? pass(`${tag} DB.setCount == ${exp.setCount}`)
    : fail(`${tag} DB.setCount expected ${exp.setCount}, got ${rows.length}`);

  (exp.sets || []).forEach((e, i) => {
    const r = rows[i];
    if (!r) return fail(`${tag} set[${i}] missing`);
    for (const k of ['status', 'exerciseId', 'sortOrder', 'plannedWeight', 'plannedReps', 'actualWeight', 'actualReps', 'actualDuration']) {
      if (e[k] !== undefined) {
        const got = r[k];
        (got === e[k] || (e[k] === null && got === null))
          ? pass(`${tag} set[${i}].${k} == ${e[k]}`)
          : fail(`${tag} set[${i}].${k} expected ${e[k]}, got ${got}`);
      }
    }
    if (e.completedAtNonNull) {
      r.completedAt !== null ? pass(`${tag} set[${i}].completedAt stamped`) : fail(`${tag} set[${i}].completedAt NULL`);
    }
  });

  // ---- Snapshot assertions ----
  const snap = exp.snapshot || {};
  if (snap.overlayState !== undefined) {
    fsm.overlayState === snap.overlayState
      ? pass(`${tag} snapshot.overlayState == '${snap.overlayState}'`)
      : fail(`${tag} snapshot.overlayState expected '${snap.overlayState}', got '${fsm.overlayState}'`);
  }
  if (snap.restRequested !== undefined) {
    fsm.restRequested === snap.restRequested
      ? pass(`${tag} snapshot.restRequested == ${snap.restRequested}`)
      : fail(`${tag} snapshot.restRequested expected ${snap.restRequested}, got ${fsm.restRequested}`);
  }
  if (snap.finishReady !== undefined) {
    fsm.finishReady === snap.finishReady
      ? pass(`${tag} snapshot.finishReady == ${snap.finishReady}`)
      : fail(`${tag} snapshot.finishReady expected ${snap.finishReady}, got ${fsm.finishReady}`);
  }
  if (snap.lastCompletedSetIsSet0) {
    fsm.lastCompletedSetId === setIds[0]
      ? pass(`${tag} snapshot.lastCompletedSetId == set0`)
      : fail(`${tag} snapshot.lastCompletedSetId wrong`);
  }
  if (snap.nextIncompleteIsSet1) {
    fsm.nextIncompleteSetId === setIds[1]
      ? pass(`${tag} snapshot.nextIncompleteSetId == set1`)
      : fail(`${tag} snapshot.nextIncompleteSetId wrong (got ${fsm.nextIncompleteSetId})`);
  }
  if (snap.nextIncompleteIsSet0) {
    fsm.nextIncompleteSetId === setIds[0]
      ? pass(`${tag} snapshot.nextIncompleteSetId == set0`)
      : fail(`${tag} snapshot.nextIncompleteSetId wrong`);
  }
  if (snap.nextIncompleteNull) {
    fsm.nextIncompleteSetId === null
      ? pass(`${tag} snapshot.nextIncompleteSetId == null`)
      : fail(`${tag} snapshot.nextIncompleteSetId expected null, got ${fsm.nextIncompleteSetId}`);
  }
  if (snap.undoCleared) {
    fsm.undoableDrop === null
      ? pass(`${tag} snapshot.undoableDrop cleared after undo`)
      : fail(`${tag} snapshot.undoableDrop should be null`);
  }

  // ---- Cue assertions ----
  if (exp.cues) {
    JSON.stringify(fsm.cues) === JSON.stringify(exp.cues)
      ? pass(`${tag} cues == ${JSON.stringify(exp.cues)}`)
      : fail(`${tag} cues expected ${JSON.stringify(exp.cues)}, got ${JSON.stringify(fsm.cues)}`);
  }
  if (exp.cuesNotReemitted) {
    const count = fsm.cues.filter(c => c === 'cue.set.completed').length;
    count === 1 ? pass(`${tag} cue.set.completed emitted exactly once (edit-after-complete silent)`)
                : fail(`${tag} cue.set.completed emitted ${count} times (BR-006 violated)`);
  }
  if (exp.sessionEndedNonNull) {
    const s = db.prepare(`SELECT endedAt FROM workout_session WHERE id = ?`).get(sessionId);
    s.endedAt !== null ? pass(`${tag} session.endedAt stamped`) : fail(`${tag} session.endedAt NULL`);
  }

  db.close();
}

function main() {
  const fixtures = [
    '01-materialization.json',
    '02-one-tap-accept.json',
    '03-fail-records-actuals.json',
    '04-drop-plus-undo.json',
    '05-undo-expiry.json',
    '06-add-set-prefill.json',
    '07-edit-after-complete-no-rest.json',
    '08-superset-interleave.json',
    '09-finish-when-all-terminal.json',
    '10-dropped-never-requests-rest.json',
  ];
  for (const f of fixtures) runFixture(f);

  if (failures === 0) { console.log('\nALL WORKOUT FSM FIXTURES PASS'); process.exit(0); }
  console.error(`\n${failures} assertion(s) failed`); process.exit(1);
}

main();
