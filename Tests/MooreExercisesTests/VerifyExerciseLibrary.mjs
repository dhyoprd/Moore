// VerifyExerciseLibrary.mjs — SC-exercises@1.0.0 seam-1 / seam-2 verifier.
// Pattern matches #19's VerifyMigrations.mjs: spins up an in-memory SQLite,
// applies assumed #19 schema + our 0004, seeds the built-in library, runs
// every fixture in Fixtures/, prints PASS/FAIL per BR, exits non-zero on fail.
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
const migrationsDir = path.join(__dirname, '..', '..', 'Sources', 'MooreExercises', 'Migrations');
const seedPath = path.join(__dirname, '..', '..', 'Sources', 'MooreExercises', 'Seed', 'builtin-library.json');

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

function freshDb(withSeed = true) {
  const d = new Database(':memory:');
  d.pragma('foreign_keys = ON');
  // Assumed #19 base (see Migrations-DEPENDS-ON-19.md)
  d.exec(`CREATE TABLE exercise (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    default_metric TEXT NOT NULL,
    equipment TEXT NOT NULL,
    is_custom INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT
  )`);
  try {
    d.exec(fs.readFileSync(path.join(migrationsDir, '0004_exercise_library.sql'), 'utf8'));
  } catch (e) {
    report('MIGRATION-0004 applies', false, e.message);
  }
  if (withSeed) {
    const seed = JSON.parse(fs.readFileSync(seedPath, 'utf8'));
    const stmt = d.prepare(`INSERT OR IGNORE INTO exercise
      (id, name, name_normalized, category, default_metric, equipment, is_custom, default_rest_sec, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)`);
    const now = new Date().toISOString();
    for (const ex of seed.exercises) {
      stmt.run(ex.id, ex.name, normalize(ex.name), ex.category, ex.defaultMetric, ex.equipment, now, now);
    }
  }
  return d;
}

const nowStr = new Date().toISOString();
function insertRow(d, row) {
  d.prepare(`INSERT INTO exercise (id,name,name_normalized,category,default_metric,equipment,is_custom,default_rest_sec,created_at,updated_at,deleted_at)
             VALUES (?,?,?,?,?,?,?,NULL,?,?,?)`)
   .run(row.id, row.name, normalize(row.name), row.category ?? 'other',
        row.defaultMetric ?? 'reps', row.equipment ?? 'other', row.isCustom ? 1 : 0,
        nowStr, nowStr, row.deleted ? nowStr : null);
}

// ------------------------------------------------------------------------
// MIGRATION + SEED
// ------------------------------------------------------------------------
{
  const d = freshDb(false);
  const cols = d.prepare(`PRAGMA table_info(exercise)`).all().map(c => c.name);
  report('SC-0004 adds name_normalized', cols.includes('name_normalized'), `cols=${cols.join(',')}`);
  report('SC-0004 adds default_rest_sec', cols.includes('default_rest_sec'), `cols=${cols.join(',')}`);
  d.close();

  const d2 = freshDb(true);
  const count = d2.prepare(`SELECT COUNT(*) AS c FROM exercise`).get().c;
  report('BR-006 seed installs all', count >= 60, `got ${count}`);
  d2.close();

  // Re-seed idempotent
  const d3 = freshDb(true);
  const before = d3.prepare(`SELECT COUNT(*) AS c FROM exercise`).get().c;
  const seed = JSON.parse(fs.readFileSync(seedPath, 'utf8'));
  const insert = d3.prepare(`INSERT OR IGNORE INTO exercise
      (id, name, name_normalized, category, default_metric, equipment, is_custom, default_rest_sec, created_at, updated_at)
      VALUES (?,?,?,?,?,?,0,NULL,?,?)`);
  const now = new Date().toISOString();
  for (const ex of seed.exercises) insert.run(ex.id, ex.name, normalize(ex.name), ex.category, ex.defaultMetric, ex.equipment, now, now);
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
      rows = d.prepare(`SELECT id, is_custom, name FROM exercise WHERE deleted_at IS NULL ORDER BY is_custom ASC, name ASC`).all();
    } else {
      rows = d.prepare(`SELECT id, is_custom, name FROM exercise WHERE deleted_at IS NULL AND name_normalized LIKE ? ORDER BY is_custom ASC, name ASC`).all(`%${q}%`);
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
    const existing = d.prepare(`SELECT * FROM exercise WHERE name_normalized = ? AND deleted_at IS NULL`).get(norm);
    const tombstoned = d.prepare(`SELECT * FROM exercise WHERE name_normalized = ? AND deleted_at IS NOT NULL`).get(norm);

    let outcome, returnedId;
    if (existing) {
      outcome = 'matchedExisting'; returnedId = existing.id;
    } else if (tombstoned) {
      outcome = tombstoned.is_custom === 1 ? 'restoredCustom' : 'restoredBuiltIn';
      d.prepare(`UPDATE exercise SET deleted_at = NULL, updated_at = ? WHERE id = ?`).run(nowStr, tombstoned.id);
      returnedId = tombstoned.id;
    } else {
      returnedId = `11111111-2222-4333-8444-555555555555`;
      d.prepare(`INSERT INTO exercise (id,name,name_normalized,category,default_metric,equipment,is_custom,default_rest_sec,created_at,updated_at)
                 VALUES (?,?,?,?,?,?,1,NULL,?,?)`)
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
      const r = d.prepare(`SELECT deleted_at FROM exercise WHERE id = ?`).get(returnedId);
      report(`${c.id}: deleted cleared`, r.deleted_at === null, `deleted_at=${r.deleted_at}`);
    }
    if (c.expectedRow) {
      const r = d.prepare(`SELECT * FROM exercise WHERE id = ?`).get(returnedId);
      const ok = r.is_custom === c.expectedRow.isCustom
              && r.name === c.expectedRow.name
              && r.name_normalized === c.expectedRow.nameNormalized
              && r.category === c.expectedRow.category
              && r.default_metric === c.expectedRow.defaultMetric
              && r.equipment === c.expectedRow.equipment;
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
      d.prepare(`UPDATE exercise SET deleted_at = ?, updated_at = ? WHERE id = ?`).run(nowStr, nowStr, c.action.tombstone);
      const row = d.prepare(`SELECT * FROM exercise WHERE id = ?`).get(c.action.tombstone);
      report(`${c.id}: still readable`, !!row, `row missing}`);
      report(`${c.id}: name resolves`, row?.name === c.expectedGetById.name, `want=${c.expectedGetById.name} got=${row?.name}`);
      report(`${c.id}: deletedAt set`, !!row?.deleted_at, `deleted_at=${row?.deleted_at}`);
    }
    if (c.action.search) {
      const norm = normalize(c.action.search);
      const rows = d.prepare(`SELECT id FROM exercise WHERE deleted_at IS NULL AND name_normalized LIKE ?`).all(`%${norm}%`);
      const ids = rows.map(r => r.id);
      const ok = c.expectedMatchIds.length === 0 ? ids.length === 0 : c.expectedMatchIds.every(m => ids.includes(m));
      report(`${c.id}: search`, ok, `want=${JSON.stringify(c.expectedMatchIds)} got=${JSON.stringify(ids)}`);
    }
    if (c.action.restore) {
      d.prepare(`UPDATE exercise SET deleted_at = NULL, updated_at = ? WHERE id = ?`).run(nowStr, c.action.restore);
      const row = d.prepare(`SELECT * FROM exercise WHERE id = ?`).get(c.action.restore);
      report(`${c.id}: deleted cleared`, row?.deleted_at === null, `deleted_at=${row?.deleted_at}`);
      const rows = d.prepare(`SELECT id FROM exercise WHERE deleted_at IS NULL`).all().map(r => r.id);
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
      const rows = d.prepare(`SELECT id FROM exercise WHERE deleted_at IS NULL AND name_normalized LIKE ?`).all(`%${norm}%`);
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
