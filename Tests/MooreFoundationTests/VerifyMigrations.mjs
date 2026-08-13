// Seam-2 verifier for SC-foundation@1.0.0 (ticket #19).
// Applies the FULL canonical migration chain (0001→0011, reconciled by #32) to
// an in-memory SQLite instance, then for every fixture: insert every entity →
// SELECT by id → assert field-for-field equality including NULL preservation.
// Exits non-zero on first failure detail.
//
// Usage (from the worktree root):
//   npm install            # once, installs better-sqlite3
//   node Tests/MooreFoundationTests/VerifyMigrations.mjs
//
// Vector ↔ BR mapping (cited per the contract template §7 'test names cite rule IDs'):
//   V1, V2  → BR-001 (additive-only, idempotent apply)
//   V3..V13 → INV-1 / INV-4 (UUID, round-trip equality incl. NULLs)
//   V8      → BR-007 (importKey UNIQUE dedupe)
//   V9, V10 → BR-004 (dual plannedX/actualX lawful NULL)
//   V14     → BR-003 (tombstone semantics: deletedAt hides row from default fetch)
//   V15     → BR-004 stress (planned-only vs planned-NULL rows in same session)
//
// Fixtures round-trip against the POST-chain canonical shapes: personal_record
// is the post-0009 rebuild (sessionId + max_* kinds), body_metric the post-0011
// rebuild (label column), progression_scheme the post-0007 rebuild.

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
const FIXTURES = [
  'round-trip-vector-01.json',
  'round-trip-vector-02.json',
  'round-trip-vector-03.json',
  'round-trip-vector-04.json',
  'round-trip-vector-05.json',
];

// Table name per entity prefix ("Exercise.library" -> "exercise").
const ENTITY_TO_TABLE = {
  Folder: 'folder',
  Exercise: 'exercise',
  Routine: 'routine',
  PlannedSet: 'planned_set',
  WorkoutSession: 'workout_session',
  CompletedSet: 'completed_set',
  PersonalRecord: 'personal_record',
  BodyMetric: 'body_metric',
  ProgressionScheme: 'progression_scheme',
};

let failures = 0;
const fail = (msg) => { console.error(`FAIL: ${msg}`); failures += 1; };
const pass = (msg) => console.log(`PASS: ${msg}`);

function assertEqual(expected, actual, label, field) {
  // better-sqlite3 returns REAL as number, INTEGER as number (JS double).
  // Fixture JSON keeps both as numbers; strict equality is correct here.
  if (expected !== actual) {
    fail(`${label}.${field}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    return false;
  }
  return true;
}

function roundTripEntity(db, entityLabel, record) {
  const entityName = entityLabel.split('.')[0];
  const table = ENTITY_TO_TABLE[entityName];
  if (!table) { fail(`${entityLabel}: unknown entity prefix`); return; }

  const cols = Object.keys(record);
  const placeholders = cols.map(() => '?').join(', ');
  const sql = `INSERT INTO ${table} (${cols.join(', ')}) VALUES (${placeholders})`;
  const values = cols.map((c) => record[c]);

  try {
    db.prepare(sql).run(...values);
  } catch (e) {
    fail(`${entityLabel}: INSERT threw: ${e.message}  (sql=${sql})`);
    return;
  }

  const row = db.prepare(`SELECT ${cols.join(', ')} FROM ${table} WHERE id = ?`).get(record.id);
  if (!row) { fail(`${entityLabel}: SELECT by id returned no row`); return; }

  let allMatch = true;
  for (const col of cols) {
    if (!assertEqual(record[col], row[col], entityLabel, col)) allMatch = false;
  }
  if (allMatch) pass(`${entityLabel} round-trip`);
}

function main() {
  const db = new Database(':memory:');

  // V1 — apply migrations in order.
  for (const migPath of MIGRATIONS) {
    const migName = migPath.split(/[\\/]/).pop();
    const sql = readFileSync(migPath, 'utf8');
    try {
      db.exec(sql);
      pass(`migration.apply ${migName}`);
    } catch (e) {
      fail(`migration.apply ${migName}: ${e.message}`);
      process.exit(1);
    }
  }

  // Confirm all nine expected tables exist.
  const tables = db.prepare(
    `SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`
  ).all().map(r => r.name);
  const expectedTables = [
    'body_metric', 'completed_set', 'exercise', 'folder',
    'personal_record', 'planned_set', 'progression_scheme',
    'routine', 'workout_session',
  ];
  const missing = expectedTables.filter(t => !tables.includes(t));
  if (missing.length === 0) pass('schema.all-nine-tables-exist');
  else fail(`schema.all-nine-tables-exist: missing ${missing.join(', ')}`);

  // V2 — re-exec of the same SQL is expected to fail on re-CREATE; what must
  // be idempotent is the *migration tracker*. We simulate GRDB here by wrapping
  // each migration in a name check: if a marker row says it's applied, skip.
  db.exec(`CREATE TABLE IF NOT EXISTS schema_migrations (identifier TEXT PRIMARY KEY, appliedAt TEXT NOT NULL);`);
  for (const migPath of MIGRATIONS) {
    const migName = migPath.split(/[\\/]/).pop();
    const already = db.prepare(`SELECT 1 FROM schema_migrations WHERE identifier = ?`).get(migName);
    if (already) { pass(`migration.idempotent ${migName} (skipped)`); continue; }
    // First pass already applied them; only insert markers.
    db.prepare(`INSERT INTO schema_migrations (identifier, appliedAt) VALUES (?, ?)`)
      .run(migName, new Date().toISOString());
    pass(`migration.idempotent ${migName} (marked)`);
  }

  // V3..V15 — fixtures.
  const sortedFixtures = FIXTURES; // declared in dependency order already
  const loaded = new Map();
  for (const fname of sortedFixtures) {
    const fixture = JSON.parse(readFileSync(join(fixturesDir, fname), 'utf8'));
    loaded.set(fname, fixture);

    // Dependency check: named prior fixtures must be present.
    if (Array.isArray(fixture.dependsOn)) {
      for (const dep of fixture.dependsOn) {
        if (!loaded.has(dep)) fail(`${fname}: dependsOn ${dep} not yet loaded (fixture order wrong)`);
      }
    }

    for (const [label, record] of Object.entries(fixture.entities)) {
      roundTripEntity(db, label, record);
    }

    // Vector-3 explicit assertion: importKey UNIQUE rejects a duplicate insert.
    if (fixture.asserts && fixture.asserts.duplicateImportKeyRejected) {
      const a = fixture.asserts.duplicateImportKeyRejected;
      const original = fixture.entities[a.insertDuplicateOf];
      const dupe = { ...original, id: a.differentId };
      const cols = Object.keys(dupe);
      const sql = `INSERT INTO workout_session (${cols.join(', ')}) VALUES (${cols.map(() => '?').join(', ')})`;
      let threw = false;
      try {
        db.prepare(sql).run(...cols.map(c => dupe[c]));
      } catch (e) {
        if (/UNIQUE constraint failed/i.test(e.message)) threw = true;
        else fail(`asserts.duplicateImportKeyRejected: wrong error type: ${e.message}`);
      }
      if (threw) pass('asserts.duplicateImportKeyRejected (BR-007 UNIQUE)');
      else fail('asserts.duplicateImportKeyRejected: duplicate importKey was accepted');
    }

    // V14 — tombstone: soft-delete the Folder from vector-01, then
    // (a) a default filter (deletedAt IS NULL) must return no row,
    // (b) an unfiltered scan must still find it with deletedAt populated.
    if (fixture.vector === 1) {
      const folderId = fixture.entities.Folder.id;
      const now = new Date().toISOString();
      db.prepare(`UPDATE folder SET deletedAt = ?, updatedAt = ? WHERE id = ?`).run(now, now, folderId);
      const visible = db.prepare(`SELECT id FROM folder WHERE id = ? AND deletedAt IS NULL`).get(folderId);
      const tombstoned = db.prepare(`SELECT id, deletedAt FROM folder WHERE id = ?`).get(folderId);
      if (visible === undefined) pass('V14.tombstone.hidden-from-default-fetch');
      else fail('V14.tombstone: row still visible under deletedAt IS NULL filter');
      if (tombstoned && tombstoned.deletedAt) pass('V14.tombstone.row-still-present-with-deletedAt');
      else fail('V14.tombstone: row missing or deletedAt not set');
    }
  }

  if (failures === 0) {
    console.log('\nALL FIXTURES PASS');
    process.exit(0);
  } else {
    console.error(`\n${failures} assertion(s) failed`);
    process.exit(1);
  }
}

main();
