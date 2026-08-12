// Seam-1/seam-2 verifier for SC-prs@1.0.0 (ticket #26).
// Mirrors Sources/MooreRecords/PREngine.swift + PersonalRecordDAO.swift in JS so
// vectors run on Windows; fresh in-memory DB per fixture; migrations 0001–0008.
//
// Usage: node Tests/MooreRecordsTests/VerifyRecords.mjs

import Database from 'better-sqlite3';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const worktreeRoot = join(here, '..', '..');
const FIXT = join(here, 'Fixtures');

const MIGRATIONS = [
  'Sources/MooreFoundation/Migrations/0001_core.sql',
  'Sources/MooreFoundation/Migrations/0002_warmup_progression.sql',
  'Sources/MooreFoundation/Migrations/0003_import_columns.sql',
  'Sources/MooreRoutines/Migrations/0005_routines_folders.sql',
  'Sources/MooreRoutines/Migrations/0006_routines_session_link.sql',
  'Sources/MooreRest/Migrations/0007_rest_fields.sql',
  'Sources/MooreRecords/Migrations/0008_personal_records.sql',
].map((p) => join(worktreeRoot, ...p.split('/')));

let failures = 0, passes = 0;
const fail = (m) => { console.error(`FAIL: ${m}`); failures += 1; };
const pass = (m) => { console.log(`PASS: ${m}`); passes += 1; };
const eq = (a, b, label) => (a === b ? pass(label) : fail(`${label}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`));
const approx = (a, b, label) => (Math.abs(a - b) < 1e-9 ? pass(label) : fail(`${label}: expected ~${b}, got ${a}`));
const sortedEq = (a, b, label) => {
  const js = (x) => JSON.stringify([...x].sort());
  js(a) === js(b) ? pass(label) : fail(`${label}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
};

// ---- JS mirror of PREngine (Sources/MooreRecords/PREngine.swift is source of truth) ----
const KINDS = ['max_1rm', 'max_volume', 'max_reps', 'max_duration'];
const PRECEDENCE = { max_1rm: 0, max_volume: 1, max_reps: 2, max_duration: 3 };
const epley = (w, r) => w * (1 + r / 30);

const isEligible = (s) => s.status === 'completed' && (s.setClass ?? 'work') === 'work';
const metricOf = (ex) => (ex.exerciseType === 'cardio' ? 'duration' : 'reps');

function valueOf(kind, s, metric) {
  if (!isEligible(s)) return null;
  switch (kind) {
    case 'max_1rm':
      return s.actualWeight > 0 && s.actualReps > 0 ? epley(s.actualWeight, s.actualReps) : null;
    case 'max_volume':
      return s.actualWeight > 0 && s.actualReps > 0 ? s.actualWeight * s.actualReps : null;
    case 'max_reps':
      return s.actualReps > 0 ? s.actualReps : null;
    case 'max_duration':
      return metric === 'duration' && s.actualDuration > 0 ? s.actualDuration : null;
  }
}

function processNewSet(set, baselines, metric) {
  if (!isEligible(set)) return null;
  const beaten = [], values = {};
  for (const kind of KINDS) {
    const row = baselines[kind];
    if (!row) continue;                       // BR-002: no baseline row → nothing to beat
    const v = valueOf(kind, set, metric);
    if (v == null) continue;                  // BR-001/BR-004 gate
    if (!(v > row.value)) continue;           // BR-003 strict exceed; ties never write
    beaten.push(kind); values[kind] = v;
  }
  if (!beaten.length) return null;
  beaten.sort((a, b) => PRECEDENCE[a] - PRECEDENCE[b]);
  const fired = { cueId: 'cue.pr.achieved', hapticClass: 'celebration', headlineKind: beaten[0], value: values[beaten[0]], exerciseId: set.exerciseId };
  return { written: beaten, beaten, values, fired };
}

function rederive(history, metric) {
  const work = history.filter((h) => h.status === 'completed' && (h.setClass ?? 'work') === 'work');
  const out = {};
  for (const kind of KINDS) {
    let best = null, holder = null;
    for (const s of work) {
      const v = valueOf(kind, s, metric);
      if (v == null) continue;
      if (best == null || v > best || (v === best && earlierWins(s, holder))) {
        best = v; holder = s;
      }
    }
    if (holder) out[kind] = { value: best, setId: holder.id, sessionId: holder.sessionId, achievedAt: holder.completedAt };
  }
  return out;
}
const earlierWins = (a, b) => {
  if (!b) return true;
  const at = a.completedAt ?? '', bt = b.completedAt ?? '';
  if (at !== bt) return at < bt;
  return a.id < b.id;
};

// ---- DB plumbing (mirrors PersonalRecordDAO) ----
function newDb() {
  const db = new Database(':memory:');
  for (const m of MIGRATIONS) db.exec(readFileSync(m, 'utf8'));
  return db;
}

function seedFixture(db, fx) {
  const now = '2026-08-12T00:00:00Z';
  const ie = db.prepare(`INSERT INTO exercise (id, name, exerciseType, isCustom, createdAt, updatedAt) VALUES (?, ?, ?, 0, ?, ?)`);
  for (const e of fx.seed.exercises ?? []) ie.run(e.id, e.name, e.exerciseType, now, now);
  const is = db.prepare(`INSERT INTO workout_session (id, startedAt, endedAt, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?)`);
  for (const s of fx.seed.sessions ?? []) is.run(s.id, s.startedAt, s.endedAt ?? null, now, now);
  let ord = 0;
  const ic = db.prepare(`
    INSERT INTO completed_set (id, sessionId, exerciseId, sortOrder, actualWeight, actualReps, actualDuration, status, setClass, completedAt, createdAt, updatedAt)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
  for (const s of fx.seed.sets ?? [])
    ic.run(s.id, s.sessionId, s.exerciseId, ord++, s.actualWeight ?? null, s.actualReps ?? null, s.actualDuration ?? null, s.status, s.setClass ?? null, s.completedAt ?? null, now, now);
  const ip = db.prepare(`
    INSERT INTO personal_record (id, exerciseId, sessionId, setId, kind, value, achievedAt, createdAt, updatedAt)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`);
  for (const p of fx.seed.personalRecords ?? [])
    ip.run(randomUUID(), p.exerciseId, p.sessionId, p.setId ?? null, p.kind, p.value, p.achievedAt, now, now);
}

function loadExerciseContext(db, exerciseId) {
  const ex = db.prepare(`SELECT * FROM exercise WHERE id = ?`).get(exerciseId);
  const history = db.prepare(`SELECT * FROM completed_set WHERE exerciseId = ? AND deletedAt IS NULL`).all(exerciseId);
  const baselines = {};
  for (const r of db.prepare(`SELECT * FROM personal_record WHERE exerciseId = ? AND deletedAt IS NULL`).all(exerciseId))
    if (!baselines[r.kind]) baselines[r.kind] = r; // INV-PR2: one row per kind; first wins on duplicates
  return { metric: metricOf(ex), history, baselines };
}

function writeFromSet(db, setId) {
  const set = db.prepare(`SELECT * FROM completed_set WHERE id = ? AND deletedAt IS NULL`).get(setId);
  if (!set) return null;
  const { metric, baselines } = loadExerciseContext(db, set.exerciseId);
  const write = processNewSet(set, baselines, metric);
  if (!write) return null;
  const now = '2026-08-12T12:00:00Z';
  const upsert = db.transaction(() => {
    for (const kind of write.written) {
      const v = write.values[kind];
      const live = db.prepare(`SELECT * FROM personal_record WHERE exerciseId = ? AND kind = ? AND deletedAt IS NULL ORDER BY achievedAt DESC`).all(set.exerciseId, kind);
      if (live.length) {
        db.prepare(`UPDATE personal_record SET value = ?, setId = ?, sessionId = ?, achievedAt = ?, updatedAt = ? WHERE id = ?`)
          .run(v, set.id, set.sessionId, set.completedAt ?? now, now, live[0].id);
        for (const stale of live.slice(1))
          db.prepare(`UPDATE personal_record SET deletedAt = ?, updatedAt = ? WHERE id = ?`).run(now, now, stale.id);
      } else {
        db.prepare(`INSERT INTO personal_record (id, exerciseId, sessionId, setId, kind, value, achievedAt, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`)
          .run(randomUUID(), set.exerciseId, set.sessionId, set.id, kind, v, set.completedAt ?? now, now, now);
      }
    }
  });
  upsert();
  return write;
}

function rederiveExercise(db, exerciseId) {
  const { metric, history } = loadExerciseContext(db, exerciseId);
  const target = rederive(history, metric);
  const now = '2026-08-12T12:00:00Z';
  const tx = db.transaction(() => {
    for (const kind of KINDS) {
      const existing = db.prepare(`SELECT * FROM personal_record WHERE exerciseId = ? AND kind = ? AND deletedAt IS NULL`).get(exerciseId, kind);
      const t = target[kind];
      if (existing && t) {
        if (existing.value !== t.value || existing.setId !== t.setId) {
          db.prepare(`UPDATE personal_record SET value = ?, setId = ?, sessionId = ?, achievedAt = ?, updatedAt = ? WHERE id = ?`)
            .run(t.value, t.setId, t.sessionId ?? existing.sessionId, t.achievedAt ?? existing.achievedAt, now, existing.id);
        }
      } else if (!existing && t) {
        db.prepare(`INSERT INTO personal_record (id, exerciseId, sessionId, setId, kind, value, achievedAt, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`)
          .run(randomUUID(), exerciseId, t.sessionId ?? '', t.setId, kind, t.value, t.achievedAt ?? now, now, now);
      } else if (existing && !t) {
        db.prepare(`UPDATE personal_record SET deletedAt = ?, updatedAt = ? WHERE id = ?`).run(now, now, existing.id);
      }
    }
  });
  tx();
}

function liveRows(db, exerciseId) {
  return db.prepare(`SELECT * FROM personal_record WHERE exerciseId = ? AND deletedAt IS NULL ORDER BY kind`).all(exerciseId);
}

// ---- Schema sanity (0008 healed shape) ----
(function schemaShape() {
  const db = newDb();
  const cols = db.prepare(`PRAGMA table_info(personal_record)`).all().map((c) => c.name);
  for (const c of ['id', 'exerciseId', 'sessionId', 'setId', 'kind', 'value', 'achievedAt', 'createdAt', 'updatedAt', 'deletedAt'])
    if (!cols.includes(c)) return fail(`schema.missing ${c} on personal_record`);
  db.prepare(`INSERT INTO exercise (id, name, exerciseType, isCustom, createdAt, updatedAt) VALUES ('ex-x','X','strength',0,'t','t')`).run();
  db.prepare(`INSERT INTO workout_session (id, startedAt, createdAt, updatedAt) VALUES ('s-x','t','t','t')`).run();
  db.prepare(`INSERT INTO personal_record (id, exerciseId, sessionId, kind, value, achievedAt, createdAt, updatedAt) VALUES ('p-x','ex-x','s-x','max_duration',90,'t','t','t')`).run();
  const bad = () => db.prepare(`INSERT INTO personal_record (id, exerciseId, sessionId, kind, value, achievedAt, createdAt, updatedAt) VALUES ('p-y','ex-x','s-x','weight',1,'t','t','t')`).run();
  let threw = false;
  try { bad(); } catch { threw = true; }
  if (!threw) return fail('schema.legacy-kind-rejected: kind=weight must violate CHECK post-0008');
  const legacyTable = db.prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name='personal_record__legacy_0001'`).get();
  if (!legacyTable) return fail('schema.legacy-preserved: personal_record__legacy_0001 must survive');
  pass('schema.personal-record.canonical');
})();

// ---- Fixture runner ----
const files = readdirSync(FIXT).filter((f) => f.endsWith('.json')).sort();
for (const fname of files) {
  const fx = JSON.parse(readFileSync(join(FIXT, fname), 'utf8'));
  console.log(`\n-- ${fname}: ${fx.label ?? ''}`);
  const db = newDb();
  seedFixture(db, fx);

  for (const v of fx.vectors ?? []) {
    const id = `${fname}.${v.id}`;

    if (v.insertSet) {
      const s = v.insertSet;
      db.prepare(`
        INSERT INTO completed_set (id, sessionId, exerciseId, sortOrder, actualWeight, actualReps, actualDuration, status, setClass, completedAt, createdAt, updatedAt)
        VALUES (?, ?, ?, 1000, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(s.id, s.sessionId, s.exerciseId, s.actualWeight ?? null, s.actualReps ?? null, s.actualDuration ?? null, s.status, s.setClass ?? null, s.completedAt ?? null, '2026-08-12T12:00:00Z', '2026-08-12T12:00:00Z');
      pass(`${id}.insert-set`);
    }

    if (v.writeFromSet) {
      const calls = Array.isArray(v.writeFromSet) ? v.writeFromSet : [v.writeFromSet];
      let lastWrite = null;
      for (const c of calls) {
        lastWrite = writeFromSet(db, c.setId);
        // Per-vector assertions apply to the LAST writeFromSet call.
      }
      const ex = v.expect;
      if (!ex) continue;
      if (ex.write === null) {
        eq(lastWrite, null, `${id}.write-null`);
      } else if (ex.write !== undefined) {
        if (!lastWrite) fail(`${id}.write: expected write, got null`);
      }
      if (ex.written) {
        if (!lastWrite) fail(`${id}.written: expected write, got null`);
        else sortedEq(lastWrite.written, ex.written, `${id}.written`);
      }
      if (ex.beaten) {
        if (!lastWrite) fail(`${id}.beaten: expected write, got null`);
        else sortedEq(lastWrite.beaten, ex.beaten, `${id}.beaten`);
      }
      if ('fired' in ex) {
        if (ex.fired === null) {
          if (lastWrite?.fired == null) pass(`${id}.fired-null`);
          else fail(`${id}.fired-null: expected null, got ${JSON.stringify(lastWrite.fired)}`);
        } else {
          if (!lastWrite?.fired) fail(`${id}.fired: expected cue, got none`);
          else {
            eq(lastWrite.fired.headlineKind, ex.fired.headlineKind, `${id}.fired.headlineKind`);
            approx(lastWrite.fired.value, ex.fired.value, `${id}.fired.value`);
            eq(lastWrite.fired.exerciseId, ex.fired.exerciseId, `${id}.fired.exerciseId`);
            eq(lastWrite.fired.cueId, 'cue.pr.achieved', `${id}.fired.cueId`);
            eq(lastWrite.fired.hapticClass, 'celebration', `${id}.fired.hapticClass`);
          }
        }
      }
    }

    if (v.editSet) {
      db.prepare(`UPDATE completed_set SET actualWeight = ?, actualReps = ?, updatedAt = ? WHERE id = ?`)
        .run(v.editSet.actualWeight ?? null, v.editSet.actualReps ?? null, '2026-08-12T12:00:00Z', v.editSet.setId);
      pass(`${id}.edit-applied`);
    }
    if (v.deleteSet) {
      db.prepare(`UPDATE completed_set SET deletedAt = ?, updatedAt = ? WHERE id = ?`)
        .run('2026-08-12T12:00:00Z', '2026-08-12T12:00:00Z', v.deleteSet.setId);
      pass(`${id}.delete-applied`);
    }
    if (v.rederive) {
      rederiveExercise(db, v.rederive.exerciseId);
      pass(`${id}.rederive-ran`);
    }

    if (v.expect && 'rows' in v.expect) {
      // rows: [] asserts every seeded exercise has NO live PR rows.
      if (v.expect.rows.length === 0) {
        for (const e of fx.seed.exercises ?? []) {
          eq(liveRows(db, e.id).length, 0, `${id}.rows-empty.${e.id}`);
        }
      }
      // Assert per-kind live rows match exactly one row each with right value/set/session.
      for (const want of v.expect.rows) {
        const rows = db.prepare(`SELECT * FROM personal_record WHERE exerciseId = ? AND kind = ? AND deletedAt IS NULL`).all(want.exerciseId, want.kind);
        if (rows.length !== 1) { fail(`${id}.row.${want.kind}: expected exactly 1 live row, got ${rows.length}`); continue; }
        const r = rows[0];
        approx(r.value, want.value, `${id}.row.${want.kind}.value`);
        if ('setId' in want) eq(r.setId, want.setId, `${id}.row.${want.kind}.setId`);
        if ('sessionId' in want) eq(r.sessionId, want.sessionId, `${id}.row.${want.kind}.sessionId`);
        if ('achievedAt' in want) eq(r.achievedAt, want.achievedAt, `${id}.row.${want.kind}.achievedAt`);
      }
      // Kinds listed are the ONLY live kinds for the exercise(s) in scope.
      const exerciseIds = [...new Set(v.expect.rows.map((r) => r.exerciseId))];
      for (const eid of exerciseIds) {
        const wantedKinds = v.expect.rows.filter((r) => r.exerciseId === eid).map((r) => r.kind);
        const liveKinds = liveRows(db, eid).map((r) => r.kind);
        sortedEq(liveKinds, wantedKinds, `${id}.rows.${eid}.only-kinds`);
      }
    }

    if (v.summary) {
      const rows = db.prepare(`SELECT * FROM personal_record WHERE deletedAt IS NULL`)
        .all()
        .filter((r) => r.sessionId === v.summary.sessionId)
        .sort((a, b) => PRECEDENCE[a.kind] - PRECEDENCE[b.kind]);
      eq(rows.length, v.summary.cards.length, `${id}.summary.count`);
      eq(rows.length >= 2, v.summary.showBanner, `${id}.summary.banner`);
      rows.forEach((r, i) => {
        const want = v.summary.cards[i];
        if (!want) return;
        eq(r.exerciseId, want.exerciseId, `${id}.summary.card${i}.exerciseId`);
        eq(r.kind, want.kind, `${id}.summary.card${i}.kind`);
        approx(r.value, want.value, `${id}.summary.card${i}.value`);
      });
    }
  }
}

console.log('');
if (failures === 0) { console.log(`ALL RECORDS FIXTURES PASS (${passes} checks)`); process.exit(0); }
console.error(`${failures} check(s) failed`); process.exit(1);
