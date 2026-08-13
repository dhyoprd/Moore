// VerifyExerciseLibrary.mjs — SC-exercises@1.0.0 seam-1 / seam-2 verifier.
// Pattern matches #19's VerifyMigrations.mjs: spins up an in-memory SQLite,
// applies the FULL canonical migration chain (0001→0011, reconciled by #32 —
// the rewritten 0004 layers category/defaultMetric/defaultRestSec/name_normalized
// onto the REAL 0001 exercise shape), seeds the built-in library, runs every
// fixture in Fixtures/, prints PASS/FAIL per BR, exits non-zero on fail.
//
// Usage: node VerifyExerciseLibrary.mjs
// Requires: better-sqlite3

import Database from 'better-sqlite3';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const fixturesDir = path.join(__dirname, 'Fixtures');
const worktreeRoot = path.join(__dirname, '..', '..');
const seedPath = path.join(worktreeRoot, 'Sources', 'MooreExercises', 'Seed', 'builtin-library.json');

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
].map((p) => path.join(worktreeRoot, ...p.split('/')));

let passCount = 0, failCount = 0;
const failures = [];
function report(name, ok, detail = '') {
  if (ok) { passCount++; console.log(`PASS: ${name}`); }
  else { failCount++; failures.push({ name, detail }); console.log(`FAIL: ${name} — ${detail}`); }
}

// Pure-function checks (BR-001)
const normalize = s => s.toLowerCase().trim().split(/\s+/).filter(Boolean).join(' ');
const displayForm = s => s.trim().split(/\s+/).filter(Boolean).join(' ');

report('BR-001 lowercase+trim+collapse', normalize('  Barbell   Bench Press  ') === 'barbell bench press');
report('BR-001 displayForm preserves casing', displayForm('  Cable   Woodchopper  ') === 'Cable Woodchopper');

// Helpers ---------------------------------------------------------------

// Seed rows write through the SAME columns the Swift/Kotlin seed loaders use
// (category + defaultMetric + name_normalized + defaultRestSec), deriving
// exerciseType per INV-IM8: duration metric ⇔ 'cardio', else 'strength'.
function seedBuiltIns(d) {
  const seed = JSON.parse(fs.readFileSync(seedPath, 'utf8'));
  const stmt = d.prepare(`INSERT OR IGNORE INTO exercise
    (id, name, exerciseType, equipmentSlug, isCustom, category, defaultMetric, defaultRestSec, name_normalized, createdAt, updatedAt)
    VALUES (?, ?, ?, ?, 0, ?, ?, NULL, ?, ?, ?)`);
  const now = new Date().toISOString();
  for (const ex of seed.exercises) {
    stmt.run(ex.id, ex.name, ex.defaultMetric === 'duration' ? 'cardio' : 'strength',
      ex.equipment ?? null, ex.category, ex.defaultMetric, normalize(ex.name), now, now);
  }
  return seed;
}

function freshDb(withSeed = true) {
  const d = new Database(':memory:');
  d.pragma('foreign_keys = ON');
  for (const m of MIGRATIONS) d.exec(fs.readFileSync(m, 'utf8'));
  if (withSeed) seedBuiltIns(d);
  return d;
}

const nowStr = new Date().toISOString();
function insertRow(d, row) {
  d.prepare(`INSERT INTO exercise (id,name,name_normalized,category,defaultMetric,equipmentSlug,isCustom,defaultRestSec,exerciseType,createdAt,updatedAt,deletedAt)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`)
    .run(row.id, row.name, normalize(row.name), row.category ?? 'other',
         row.defaultMetric ?? 'reps', row.equipment ?? 'other', row.isCustom ? 1 : 0, null,
         row.isCustom ? 'custom' : (row.defaultMetric === 'duration' ? 'cardio' : 'strength'),
         nowStr, nowStr, row.deleted ? nowStr : null);
}

// ------------------------------------------------------------------------
// MIGRATION + SEED
// ------------------------------------------------------------------------
{
  const d = freshDb(false);
  const cols = d.prepare(`PRAGMA table_info(exercise)`).all().map(c => c.name);
  report('SC-0004 adds name_normalized', cols.includes('name_normalized'), `cols=${cols.join(',')}`);
  report('SC-0004 adds category', cols.includes('category'), `cols=${cols.join(',')}`);
  report('SC-0004 adds defaultMetric', cols.includes('defaultMetric'), `cols=${cols.join(',')}`);
  report('SC-0004 adds defaultRestSec', cols.includes('defaultRestSec'), `cols=${cols.join(',')}`);
  // Indexes must target the REAL 0001 tombstone column (camelCase deletedAt).
  const idx = d.prepare(`SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='exercise' AND name LIKE 'idx_exercise_%'`).all();
  report('SC-0004 indexes present', idx.length === 2, `idx=${idx.map(i => i.name).join(',')}`);
  report('SC-0004 indexes use deletedAt', idx.every(i => i.sql.includes('deletedAt')), `sql=${idx.map(i => i.sql).join(' | ')}`);
  // defaultMetric CHECK vocabulary ('reps'|'duration'; NULL passes).
  const badMetric = (() => { try {
    d.prepare(`INSERT INTO exercise (id,name,exerciseType,isCustom,defaultMetric,createdAt,updatedAt) VALUES ('x','X','strength',0,'sets','t','t')`).run();
    return false;
  } catch { return true; } })();
  report('SC-0004 defaultMetric CHECK rejects other values', badMetric);
  d.close();

  const d2 = freshDb(true);
  const count = d2.prepare(`SELECT COUNT(*) AS c FROM exercise`).get().c;
  report('BR-006 seed installs all', count >= 60, `got ${count}`);
  // #32 AC: the seed populates category + defaultMetric on EVERY built-in row.
  const unclassified = d2.prepare(`SELECT COUNT(*) AS c FROM exercise WHERE category IS NULL OR defaultMetric IS NULL`).get().c;
  report('BR-006 seed populates category+defaultMetric on all rows', unclassified === 0, `${unclassified} rows missing category/defaultMetric`);
  const badBucket = d2.prepare(`SELECT COUNT(*) AS c FROM exercise WHERE category NOT IN
    ('chest','back','shoulders','biceps','triceps','forearms','core','quads','hamstrings','glutes','calves','fullBody','cardio','other')`).get().c;
  report('BR-004 seed categories are the analytics taxonomy', badBucket === 0, `${badBucket} rows outside the §3b enum`);
  const badNormalized = d2.prepare(`SELECT COUNT(*) AS c FROM exercise WHERE name_normalized != lower(trim(name))`).get().c;
  report('BR-001 seed name_normalized backfilled', badNormalized === 0, `${badNormalized} rows drifted`);
  d2.close();

  // Re-seed idempotent
  const d3 = freshDb(true);
  const before = d3.prepare(`SELECT COUNT(*) AS c FROM exercise`).get().c;
  seedBuiltIns(d3);
  const after = d3.prepare(`SELECT COUNT(*) AS c FROM exercise`).get().c;
  report('BR-006 re-seed idempotent', before === after, `before=${before} after=${after}`);
  d3.close();
}

// ------------------------------------------------------------------------
// FIXTURES
// ------------------------------------------------------------------------
const fixtures = fs.readdirSync(fixturesDir).filter(f => f.endsWith('.json')).sort();
report('fixtures found', fixtures.length >= 4, fixtures.join(','));

// --- match-normalization ---
{
  const fx = JSON.parse(fs.readFileSync(path.join(fixturesDir, 'match-normalization.json'), 'utf8'));
  for (const c of fx.cases) {
    const d = freshDb(true);
    // Override library to just the fixture's set so test is deterministic
    d.exec(`DELETE FROM exercise`);
    for (const ex of fx.library) insertRow(d, ex);

    const q = normalize(c.query);
    let rows;
    if (q === '') {
      rows = d.prepare(`SELECT id, isCustom, name FROM exercise WHERE deletedAt IS NULL ORDER BY isCustom ASC, name ASC`).all();
    } else {
      rows = d.prepare(`SELECT id, isCustom, name FROM exercise WHERE deletedAt IS NULL AND name_normalized LIKE ? ORDER BY isCustom ASC, name ASC`).all(`%${q}%`);
    }
    const ids = rows.map(r => r.id);
    if (c.expectedTopHit) report(`${c.id}: topHit`, rows[0]?.id === c.expectedTopHit, `want=${c.expectedTopHit} got=${rows[0]?.id}`);
    if (c.expectedMatchIds) report(`${c.id}: ids`, c.expectedMatchIds.every(m => ids.includes(m)), `want=[${c.expectedMatchIds}] got=[${ids}]`);
    if (c.expectedMatchIdsContains) report(`${c.id}: contains`, c.expectedMatchIdsContains.every(m => ids.includes(m)), `want=[${c.expectedMatchIdsContains}] got=[${ids}]`);
    d.close();
  }
}

// --- custom-create (BR-005 full) ---
{
  const fx = JSON.parse(fs.readFileSync(path.join(fixturesDir, 'custom-create.json'), 'utf8'));
  for (const c of fx.cases) {
    const d = freshDb(false);
    for (const ex of (c.preCondition.library ?? [])) insertRow(d, ex);

    const norm = normalize(c.input.name);
    const existing = d.prepare(`SELECT * FROM exercise WHERE name_normalized = ? AND deletedAt IS NULL`).get(norm);
    const tombstoned = d.prepare(`SELECT * FROM exercise WHERE name_normalized = ? AND deletedAt IS NOT NULL`).get(norm);

    let outcome, returnedId;
    if (existing) {
      outcome = 'matchedExisting'; returnedId = existing.id;
    } else if (tombstoned) {
      outcome = tombstoned.isCustom === 1 ? 'restoredCustom' : 'restoredBuiltIn';
      d.prepare(`UPDATE exercise SET deletedAt = NULL, updatedAt = ? WHERE id = ?`).run(nowStr, tombstoned.id);
      returnedId = tombstoned.id;
    } else {
      returnedId = `11111111-2222-4333-8444-555555555555`;
      d.prepare(`INSERT INTO exercise (id,name,name_normalized,category,defaultMetric,equipmentSlug,isCustom,defaultRestSec,exerciseType,createdAt,updatedAt)
                 VALUES (?,?,?,?,?,?,1,NULL,'custom',?,?)`)
        .run(returnedId, displayForm(c.input.name), norm, c.input.category, c.input.defaultMetric, c.input.equipment, nowStr, nowStr);
      outcome = 'inserted';
    }

    report(`${c.id}: outcome`, outcome === c.expectedOutcome, `want=${c.expectedOutcome} got=${outcome}`);
    if (c.expectedReturnedId) report(`${c.id}: id`, returnedId === c.expectedReturnedId, `want=${c.expectedReturnedId} got=${returnedId}`);
    if (c.expectedIdFormat === 'uuid') {
      const ok = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(returnedId);
      report(`${c.id}: uuid format`, ok, `got=${returnedId}`);
    }
    if (c.expectedRowCountAfter !== undefined) {
      const actual = d.prepare(`SELECT COUNT(*) AS c FROM exercise`).get().c;
      report(`${c.id}: row count`, actual === c.expectedRowCountAfter, `want=${c.expectedRowCountAfter} got=${actual}`);
    }
    if (c.expectedDeletedCleared) {
      const r = d.prepare(`SELECT deletedAt FROM exercise WHERE id = ?`).get(returnedId);
      report(`${c.id}: deleted cleared`, r.deletedAt === null, `deletedAt=${r.deletedAt}`);
    }
    if (c.expectedRow) {
      const r = d.prepare(`SELECT * FROM exercise WHERE id = ?`).get(returnedId);
      const ok = r.isCustom === c.expectedRow.isCustom
              && r.name === c.expectedRow.name
              && r.name_normalized === c.expectedRow.nameNormalized
              && r.category === c.expectedRow.category
              && r.defaultMetric === c.expectedRow.defaultMetric
              && r.equipmentSlug === c.expectedRow.equipment;
      report(`${c.id}: stored row`, ok, `row=${JSON.stringify(r)}`);
    }
    d.close();
  }
}

// --- tombstone-restore ---
{
  const fx = JSON.parse(fs.readFileSync(path.join(fixturesDir, 'tombstone-restore.json'), 'utf8'));
  for (const c of fx.cases) {
    const d = freshDb(false);
    for (const ex of (c.preCondition.library ?? [])) insertRow(d, ex);

    if (c.action.tombstone) {
      d.prepare(`UPDATE exercise SET deletedAt = ?, updatedAt = ? WHERE id = ?`).run(nowStr, nowStr, c.action.tombstone);
      const row = d.prepare(`SELECT * FROM exercise WHERE id = ?`).get(c.action.tombstone);
      report(`${c.id}: still readable`, !!row, `row missing}`);
      report(`${c.id}: name resolves`, row?.name === c.expectedGetById.name, `want=${c.expectedGetById.name} got=${row?.name}`);
      report(`${c.id}: deletedAt set`, !!row?.deletedAt, `deletedAt=${row?.deletedAt}`);
    }
    if (c.action.search) {
      const norm = normalize(c.action.search);
      const rows = d.prepare(`SELECT id FROM exercise WHERE deletedAt IS NULL AND name_normalized LIKE ?`).all(`%${norm}%`);
      const ids = rows.map(r => r.id);
      const ok = c.expectedMatchIds.length === 0 ? ids.length === 0 : c.expectedMatchIds.every(m => ids.includes(m));
      report(`${c.id}: search`, ok, `want=${JSON.stringify(c.expectedMatchIds)} got=${JSON.stringify(ids)}`);
    }
    if (c.action.restore) {
      d.prepare(`UPDATE exercise SET deletedAt = NULL, updatedAt = ? WHERE id = ?`).run(nowStr, c.action.restore);
      const row = d.prepare(`SELECT * FROM exercise WHERE id = ?`).get(c.action.restore);
      report(`${c.id}: deleted cleared`, row?.deletedAt === null, `deletedAt=${row?.deletedAt}`);
      const rows = d.prepare(`SELECT id FROM exercise WHERE deletedAt IS NULL`).all().map(r => r.id);
      report(`${c.id}: searchable`, c.expectedSearchAfter.every(m => rows.includes(m)), `want=${c.expectedSearchAfter} got=${rows}`);
    }
    d.close();
  }
}

// --- no-results-state ---
{
  const fx = JSON.parse(fs.readFileSync(path.join(fixturesDir, 'no-results-state.json'), 'utf8'));
  for (const c of fx.cases) {
    const d = freshDb(false);
    for (const ex of (c.preCondition.library ?? [])) insertRow(d, ex);

    const norm = normalize(c.action.search);
    let state;
    if (norm === '') {
      state = 'idle';
    } else {
      const rows = d.prepare(`SELECT id FROM exercise WHERE deletedAt IS NULL AND name_normalized LIKE ?`).all(`%${norm}%`);
      state = rows.length === 0 ? 'noResults' : 'searching';
    }
    report(`${c.id}: state`, state === c.expectedState, `want=${c.expectedState} got=${state}`);
    d.close();
  }
}

// ------------------------------------------------------------------------
console.log(`\n${passCount} passed, ${failCount} failed`);
if (failCount > 0) {
  console.log('\nFailures:');
  for (const f of failures) console.log(`  - ${f.name}: ${f.detail}`);
  process.exit(1);
}
