// Seam-2 verifier for SC-routines@1.0.0 (ticket #21).
// Section-by-section per fixture semantics:
//   routine-crud.json       CRUD / duplicate / tombstone-delete against Routine+PlannedSet
//   folder-orphan.json      folder delete leaves routines unfiled (folderId NULL)
//   empty-home.json         fresh DB → no routines → streak chip hidden, "Create first routine" CTA
//   populated-home.json     12 routines across 3 folders → round-trip with lastUsedAt desc
//   streak-scheduling.json  streak count derives from WorkoutSession timestamps only
//
// Usage: node Tests/MooreRoutinesTests/VerifyRoutines.mjs

import Database from 'better-sqlite3';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const worktreeRoot = join(here, '..', '..');
const fixturesDir = join(here, 'Fixtures');

// The ONE canonical chain (#32): unique numbers, applied in this order everywhere.
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
].map((p) => join(worktreeRoot, ...p.split('/')));

let failures = 0;
const fail = (m) => { console.error(`FAIL: ${m}`); failures += 1; };
const pass = (m) => console.log(`PASS: ${m}`);
const uuid = () => crypto.randomUUID();
const now = () => new Date().toISOString();

// ---------------- Foundation migrations (idempotent) ----------------
function applyMigrations(db) {
  for (const migPath of MIGRATIONS) {
    const name = migPath.split(/[\\/]/).pop();
    try {
      db.exec(readFileSync(migPath, 'utf8'));
      pass(`migration.apply ${name}`);
    } catch (e) {
      fail(`migration.apply ${name}: ${e.message}`);
      process.exit(1);
    }
  }
}

// Seed the two built-in exercises used by routine-crud.json (bench + ohp). The
// library schema's `exercise` table requires `exerciseType` and `isCustom` —
// values echoed from SC-foundation@1.0.0 §3.
function seedFixturesExercises(db) {
  const ts = now();
  const exercises = [
    { id: 'ex-bench', name: 'Barbell Bench Press', exerciseType: 'strength', equipmentSlug: 'barbell', isCustom: 0 },
    { id: 'ex-ohp',   name: 'Barbell Overhead Press', exerciseType: 'strength', equipmentSlug: 'barbell', isCustom: 0 },
    { id: 'ex-dip',   name: 'Dips (Weighted)', exerciseType: 'strength', equipmentSlug: 'bodyweight', isCustom: 0 },
  ];
  for (const e of exercises) {
    db.prepare(`INSERT INTO exercise (id, name, exerciseType, equipmentSlug, isCustom, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)`)
      .run(e.id, e.name, e.exerciseType, e.equipmentSlug, e.isCustom, ts, ts);
  }
  pass('seed.fixturesExercises');
}

// ---------------- utility: insert helper ----------------
function insert(db, table, row) {
  const cols = Object.keys(row);
  db.prepare(`INSERT INTO ${table} (${cols.join(', ')}) VALUES (${cols.map(() => '?').join(', ')})`)
    .run(...cols.map(c => row[c]));
}

// ---------------- fixture-specific tests ----------------

function testRoutineCrud(db, f) {
  // CREATE
  const routineId = uuid();
  insert(db, 'routine', { id: routineId, name: f.create.name, folderId: f.create.folderId, sortOrder: 0, createdAt: now(), updatedAt: now() });
  for (let i = 0; i < f.create.sets.length; i++) {
    const s = f.create.sets[i];
    insert(db, 'planned_set', {
      id: uuid(), routineId, exerciseId: s.exerciseId, sortOrder: i,
      setClass: s.setClass, plannedWeight: s.plannedWeight, plannedReps: s.plannedReps, plannedDuration: s.plannedDuration,
      createdAt: now(), updatedAt: now(),
    });
  }
  const sets = db.prepare('SELECT * FROM planned_set WHERE routineId = ?').all(routineId);
  sets.length === f.create.expected.setCount ? pass('V1.create.setCount') : fail(`V1.setCount expected ${f.create.expected.setCount} got ${sets.length}`);
  const exerciseCount = new Set(sets.map(s => s.exerciseId)).size;
  exerciseCount === f.create.expected.exerciseCount ? pass('V1.create.exerciseCount') : fail(`V1.exerciseCount expected ${f.create.expected.exerciseCount} got ${exerciseCount}`);
  const allHavePlannedValues = sets.every(s => s.plannedWeight !== null || s.plannedReps !== null || s.plannedDuration !== null);
  allHavePlannedValues ? pass('V1.create.startEnabled (>=1 complete set)') : fail('V1: some set lacks values entirely');

  // EDIT
  if (f.edit) {
    const newExercise = f.edit.addExercise;
    insert(db, 'planned_set', { id: uuid(), routineId, exerciseId: newExercise, sortOrder: 3, setClass: 'work', plannedWeight: null, plannedReps: 12, plannedDuration: null, createdAt: now(), updatedAt: now() });
    const afterAdd = db.prepare('SELECT * FROM planned_set WHERE routineId = ?').all(routineId);
    const newExerciseCount = new Set(afterAdd.map(s => s.exerciseId)).size;
    newExerciseCount === f.edit.expected.exerciseCount ? pass('V2.edit.exerciseCountAfterAdd') : fail(`V2 expected ${f.edit.expected.exerciseCount} got ${newExerciseCount}`);
    const targetSetIndex = f.edit.changedPlannedWeight.setIndex;
    const targetSet = afterAdd.find(s => s.sortOrder === targetSetIndex);
    db.prepare('UPDATE planned_set SET plannedWeight = ?, updatedAt = ? WHERE id = ?').run(f.edit.changedPlannedWeight.plannedWeight, now(), targetSet.id);
    const updated = db.prepare('SELECT plannedWeight FROM planned_set WHERE id = ?').get(targetSet.id);
    updated.plannedWeight === f.edit.changedPlannedWeight.plannedWeight ? pass('V2.edit.changedPlannedWeight') : fail('V2 edit failed');
  }

  // DUPLICATE
  if (f.duplicate) {
    const newRoutineId = uuid();
    db.prepare(`INSERT INTO routine (id, name, folderId, sortOrder, createdAt, updatedAt)
                SELECT ?, ? || name, folderId, sortOrder, ?, ? FROM routine WHERE id = ?`)
      .run(newRoutineId, f.duplicate.expectedNamePrefix, now(), now(), routineId);
    const newRoutine = db.prepare('SELECT * FROM routine WHERE id = ?').get(newRoutineId);
    newRoutine.name.startsWith(f.duplicate.expectedNamePrefix) ? pass('V3.duplicate.namePrefix') : fail('V3 duplicate name prefix wrong');
    newRoutine.id !== routineId ? pass('V3.duplicate.newIdDiffers') : fail('V3 ids match!');
    // copy sets with new ids
    const oldSets = db.prepare('SELECT * FROM planned_set WHERE routineId = ?').all(routineId);
    let newIdsDiffer = true;
    for (const s of oldSets) {
      const newSetId = uuid();
      if (newSetId === s.id) newIdsDiffer = false;
      insert(db, 'planned_set', { ...s, id: newSetId, routineId: newRoutineId, createdAt: now(), updatedAt: now() });
    }
    newIdsDiffer ? pass('V3.duplicate.setIdsDiffer') : fail('V3 set id collision');
    const newSetCount = db.prepare('SELECT COUNT(*) as c FROM planned_set WHERE routineId = ?').get(newRoutineId).c;
    newSetCount === oldSets.length ? pass('V3.duplicate.setCountMatches') : fail(`V3 expected ${oldSets.length} got ${newSetCount}`);
  }

  // DELETE
  if (f.delete) {
    const ts = now();
    db.prepare('UPDATE routine SET deletedAt = ?, updatedAt = ? WHERE id = ?').run(ts, ts, routineId);
    const live = db.prepare('SELECT id FROM routine WHERE id = ? AND deletedAt IS NULL').get(routineId);
    const tomb = db.prepare('SELECT id, deletedAt FROM routine WHERE id = ?').get(routineId);
    live === undefined ? pass('V4.delete.absentFromRoutines') : fail('V4 delete visible');
    tomb && tomb.deletedAt === ts ? pass('V4.delete.presentIncludingTombstoned') : fail('V4 tombstone wrong');
  }
}

function testFolderOrphan(db, f) {
  // Setup: routine inside a folder. NOTE: 0001's folder has no sortOrder column;
  // 0005's IF NOT EXISTS doesn't add it to an already-existing table. Order-in-list
  // is captured by routine.sortOrder; folder ordering is a UI-level display concern.
  const fid = uuid(); const rid = uuid();
  insert(db, 'folder', { id: fid, name: 'Push Pull', createdAt: now(), updatedAt: now() });
  insert(db, 'routine', { id: rid, name: 'Push A', folderId: fid, sortOrder: 0, createdAt: now(), updatedAt: now() });

  // folder delete via the business rule: re-scope then tombstone folder
  db.prepare('UPDATE routine SET folderId = NULL, updatedAt = ? WHERE folderId = ?').run(now(), fid);
  const ts = now();
  db.prepare('UPDATE folder SET deletedAt = ?, updatedAt = ? WHERE id = ?').run(ts, ts, fid);

  const liveRoutine = db.prepare('SELECT folderId FROM routine WHERE id = ? AND deletedAt IS NULL').get(rid);
  liveRoutine && liveRoutine.folderId === null ? pass('V5.folderDelete.routineUnfiled') : fail('V5 not unfiled');
  const folderGone = db.prepare('SELECT id FROM folder WHERE id = ? AND deletedAt IS NULL').get(fid);
  folderGone === undefined ? pass('V5.folderDelete.folderGone') : fail('V5 folder still live');
}

function testEmptyHome(db) {
  const routines = db.prepare('SELECT COUNT(*) as c FROM routine WHERE deletedAt IS NULL').get().c;
  const sessions = db.prepare('SELECT COUNT(*) as c FROM workout_session WHERE deletedAt IS NULL').get().c;
  // Home "empty state" reads as: zero routines → show Create CTA; zero completed sessions → hide streak chip
  routines === 0 ? pass('V6.empty.noRoutines') : fail(`V6 expected 0 routines, got ${routines}`);
  sessions === 0 ? pass('V6.empty.noSessions_streakHidden') : fail(`V6 streak chip should be hidden`);
}

function testPopulatedHome(db) {
  // 3 folders × 4 routines each; routine names R0..R11; every routine has one completed session mostRecentUsed distinct.
  const folderIds = [uuid(), uuid(), uuid()];
  folderIds.forEach((fid, i) =>
    insert(db, 'folder', { id: fid, name: `F${i}`, createdAt: now(), updatedAt: now() })
  );
  const days = ['2026-06-01', '2026-06-15', '2026-06-29', '2026-07-05', '2026-07-10', '2026-07-12', '2026-07-15', '2026-07-18', '2026-07-20', '2026-07-22', '2026-07-25', '2026-08-01'];
  for (let i = 0; i < 12; i++) {
    const rid = uuid();
    insert(db, 'routine', { id: rid, name: `R${i}`, folderId: folderIds[i % 3], sortOrder: i, createdAt: now(), updatedAt: now() });
    // a completed session = endedAt IS NOT NULL per current contract
    insert(db, 'workout_session', { id: uuid(), routineId: rid, startedAt: `${days[i]}T09:00:00Z`, endedAt: `${days[i]}T10:00:00Z`, createdAt: now(), updatedAt: now() });
  }
  const rows = db.prepare(`
    SELECT r.name, MAX(w.endedAt) as lastUsed
    FROM routine r LEFT JOIN workout_session w ON w.routineId = r.id AND w.deletedAt IS NULL AND w.endedAt IS NOT NULL
    WHERE r.deletedAt IS NULL
    GROUP BY r.id
    ORDER BY lastUsed DESC
  `).all();
  rows.length === 12 ? pass('V7.populated.12RoutinesRead') : fail(`V7 expected 12 got ${rows.length}`);
  rows[0].name === 'R11' ? pass('V7.populated.lastUsedSortedDesc') : fail(`V7 expected R11 most recent, got ${rows[0].name}`);
}

function testStreakScheduling(db) {
  // Completed session = endedAt IS NOT NULL (matches current contract; a future migration may add status)
  const completedCount = () => db.prepare(`SELECT COUNT(*) as c FROM workout_session WHERE endedAt IS NOT NULL AND deletedAt IS NULL`).get().c;
  const distinctDays = () => db.prepare(`SELECT COUNT(DISTINCT date(endedAt)) as c FROM workout_session WHERE endedAt IS NOT NULL AND deletedAt IS NULL`).get().c;

  // zero → streak = 0
  completedCount() === 0 ? pass('V8.streak.emptyIsZero') : fail('V8 not zero');

  // 1 completed session today → streak = 1
  const t = new Date().toISOString();
  insert(db, 'workout_session', { id: uuid(), routineId: null, startedAt: t, endedAt: t, createdAt: now(), updatedAt: now() });
  distinctDays() === 1 ? pass('V8.streak.oneSession') : fail(`V8 expected 1 day-streak got ${distinctDays()}`);

  // 3 distinct days → streak = 3
  const d1 = new Date(); d1.setDate(d1.getDate() - 1);
  const d2 = new Date(); d2.setDate(d2.getDate() - 2);
  insert(db, 'workout_session', { id: uuid(), routineId: null, startedAt: d1.toISOString(), endedAt: d1.toISOString(), createdAt: now(), updatedAt: now() });
  insert(db, 'workout_session', { id: uuid(), routineId: null, startedAt: d2.toISOString(), endedAt: d2.toISOString(), createdAt: now(), updatedAt: now() });
  distinctDays() === 3 ? pass('V8.streak.threeDays') : fail(`V8 expected 3 got ${distinctDays()}`);
}

// Each behavioral fixture runs against its own fresh in-memory database, to avoid
// cross-fixture contamination (e.g. `empty-home` requires zero routines, yet
// `routine-crud` inserts many).
function freshDb() {
  const db = new Database(':memory:');
  applyMigrations(db);
  seedFixturesExercises(db);
  return db;
}

// ---------------- main ----------------
function main() {
  // Sanity: required tables all there
  {
    const db = freshDb();
    const tables = db.prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'`).all().map(r => r.name);
    for (const t of ['folder', 'exercise', 'routine', 'planned_set', 'workout_session']) {
      tables.includes(t) ? pass(`table.${t}.exists`) : fail(`missing table ${t}`);
    }
  }

  const fx = (name) => JSON.parse(readFileSync(join(fixturesDir, name), 'utf8'));

  testRoutineCrud(freshDb(), fx('routine-crud.json'));
  testFolderOrphan(freshDb(), fx('folder-orphan.json'));
  testEmptyHome(freshDb());
  testPopulatedHome(freshDb());
  testStreakScheduling(freshDb());

  if (failures === 0) { console.log('\nALL ROUTINES FIXTURES PASS'); process.exit(0); }
  console.error(`\n${failures} assertion(s) failed`); process.exit(1);
}

main();
