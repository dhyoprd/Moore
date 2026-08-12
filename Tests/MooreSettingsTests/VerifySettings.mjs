// Seam-1 (logic) + seam-2 (persistence) verifier for SC-settings@1.0.0 (ticket #28).
// Mirrors Sources/MooreSettings/SettingsEngine.swift + SettingsDAO.swift in JS so
// vectors run on Windows; fresh in-memory DB per fixture; full migration chain:
//   0001-0003 (foundation), 0005-0006 (routines), 0007_progression_full,
//   0007_rest_fields, 0008 (personal records), 0009 (body metrics, this contract).
// 0004 is skipped per SC-rest's drift note (rewritten 0004 targets a shape this
// chain does not have; the settings surface only needs 0001's exercise columns).
//
// Fixture semantics:
//   unit-conversion-math.json        BR-002/BR-003  ratio math, 1dp display / 2dp storage, entry respect
//   unit-toggle-display-only.json    BR-001/BR-004/INV-ST1  toggle flips displays, never rewrites data
//   rest-defaults-persist.json       BR-005 + SC-rest INV-S2  upsert persists; re-seed never resets
//   bodymetric-add-list.json         BR-006/BR-007  CRUD create + date-descending trend list
//   bodymetric-update-delete.json    BR-006  update/delete tombstone + validation gate
//   bodymetric-migration-shape.json  §3d/INV-ST6  0009 rebuild: remap, label column, legacy preserved
//   export-manifest-completeness     BR-008/BR-009  ten-table manifest, tombstone counts, naming
//   backup-roundtrip.json            BR-008/INV-ST3  file copy re-opens; counts + hash match (AC seam-2)
//   tombstone-list-restore.json      BR-010/INV-ST4  custom tombstones listed; restore clears deletedAt
//   cloud-sync-greyed.json           BR-011/INV-ST5  permanently disabled, gate copy, zero writes
//   hevy-import-stub.json            BR-012/INV-ST5  stub blocked by #30, zero writes
//   empty-state-keys.json            BR-013  #14's nineteen keys + SC-foundation §6 keys verbatim
//
// Usage: node Tests/MooreSettingsTests/VerifySettings.mjs

import Database from 'better-sqlite3';
import { readFileSync, readdirSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const worktreeRoot = join(here, '..', '..');
const FIXT = join(here, 'Fixtures');

// Full migration chain (0004 excluded per drift note above).
const MIGRATIONS = [
  'Sources/MooreFoundation/Migrations/0001_core.sql',
  'Sources/MooreFoundation/Migrations/0002_warmup_progression.sql',
  'Sources/MooreFoundation/Migrations/0003_import_columns.sql',
  'Sources/MooreRoutines/Migrations/0005_routines_folders.sql',
  'Sources/MooreRoutines/Migrations/0006_routines_session_link.sql',
  'Sources/MooreProgression/Migrations/0007_progression_full.sql',
  'Sources/MooreRest/Migrations/0007_rest_fields.sql',
  'Sources/MooreRecords/Migrations/0008_personal_records.sql',
  'Sources/MooreSettings/Migrations/0009_body_metrics.sql',
].map((p) => join(worktreeRoot, ...p.split('/')));
const MIG_0009 = MIGRATIONS[MIGRATIONS.length - 1];
const MIGRATIONS_PRE_0009 = MIGRATIONS.slice(0, -1);

// 0007's idempotent seed tail (SC-rest INV-S2 re-seed probe, fixture V5).
const REST_SEED_SQL = `
  INSERT OR IGNORE INTO app_setting (key, value, updatedAt) VALUES
    ('defaultRestCompoundSec',  '180', strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    ('defaultRestIsolationSec', '90',  strftime('%Y-%m-%dT%H:%M:%fZ','now'));
`;

const SEED_NOW = '2026-08-13T08:00:00Z';

let failures = 0, passes = 0;
const fail = (m) => { console.error(`FAIL: ${m}`); failures += 1; };
const pass = (m) => { console.log(`PASS: ${m}`); passes += 1; };
const eq = (a, b, label) => (a === b ? pass(label) : fail(`${label}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`));
const approx = (a, b, label) => (Number.isFinite(a) && Math.abs(a - b) < 1e-9 ? pass(label) : fail(`${label}: expected ~${b}, got ${a}`));
// Key-order-insensitive deep compare (JSON.stringify is order-dependent).
function normalizeKeys(x) {
  if (Array.isArray(x)) return x.map(normalizeKeys);
  if (x && typeof x === 'object') {
    const out = {};
    for (const k of Object.keys(x).sort()) out[k] = normalizeKeys(x[k]);
    return out;
  }
  return x;
}
const deepEq = (a, b, label) => {
  const js = (x) => JSON.stringify(normalizeKeys(x));
  js(a) === js(b) ? pass(label) : fail(`${label}: expected ${js(b)}, got ${js(a)}`);
};

// ---------------------------------------------------------------------------
// JS mirror of SettingsEngine (Sources/MooreSettings/SettingsEngine.swift is
// the source of truth; both are pure + deterministic, so this mirror IS the
// seam-1 check on hosts without a Swift toolchain).
// ---------------------------------------------------------------------------
const KG_PER_LB = 2.20462;                     // BR-002 frozen ratio
const roundAway = (value, decimals) => {       // half-away-from-zero
  const f = 10 ** decimals;
  const sign = value < 0 ? -1 : 1;
  return sign * Math.round(Math.abs(value) * f) / f;
};
const kgToLb = (kg) => kg * KG_PER_LB;
const lbToKg = (lb) => lb / KG_PER_LB;
const roundDisplay = (v) => roundAway(v, 1);   // BR-002 display precision
const roundStorage = (v) => roundAway(v, 2);   // BR-002 storage precision
const displayValue = (rawKg, unit) => (unit === 'kg' ? roundDisplay(rawKg) : roundDisplay(kgToLb(rawKg)));
const displayString = (rawKg, unit) => `${displayValue(rawKg, unit).toFixed(1)} ${unit}`;
const entryToStorage = (entered, unit) => (unit === 'kg' ? roundStorage(entered) : roundStorage(lbToKg(entered)));

// BR-004: row carries its own unit; weight units convert, everything else
// (pct / cm / in) passes through at 1dp.
const displayBodyMetric = (value, rowUnit, target) => {
  if (rowUnit === 'kg') return target === 'kg' ? roundDisplay(value) : roundDisplay(kgToLb(value));
  if (rowUnit === 'lb') return target === 'lb' ? roundDisplay(value) : roundDisplay(lbToKg(value));
  return roundDisplay(value);
};
const displayBodyMetricUnit = (rowUnit, target) => (rowUnit === 'kg' || rowUnit === 'lb' ? target : rowUnit);
const displayBodyMetricString = (value, rowUnit, target) =>
  `${displayBodyMetric(value, rowUnit, target).toFixed(1)} ${displayBodyMetricUnit(rowUnit, target)}`;

// BR-008/BR-009 export manifest mirror.
const BACKUP_SUFFIX = '.moore-backup';
const EXPORT_FORMAT = 'sqlite-file-copy';
const CORE_TABLES = [
  'folder', 'exercise', 'routine', 'planned_set', 'workout_session',
  'completed_set', 'personal_record', 'body_metric', 'progression_scheme', 'app_setting',
];
const backupFileName = (exportedAt) => `moore-${exportedAt.replaceAll(':', '-')}${BACKUP_SUFFIX}`;
function buildExportManifest(tableStats, exportedAt) {
  const byName = Object.fromEntries(tableStats.map((s) => [s.table, s]));
  return {
    fileName: backupFileName(exportedAt),
    exportedAt,
    format: EXPORT_FORMAT,
    includesTombstones: true,
    includesPlannedColumns: true,
    tables: CORE_TABLES.map((name) => byName[name] ?? { table: name, rowCount: 0, tombstoneCount: 0 }),
  };
}

// BR-010 tombstone listing mirror (pure filter/sort).
const tombstonedCustomExercises = (rows) =>
  rows
    .filter((r) => r.isCustom === 1 && r.deletedAt != null)
    .sort((a, b) => (a.deletedAt === b.deletedAt ? a.name.localeCompare(b.name) : a.deletedAt < b.deletedAt ? 1 : -1));

// BR-011/BR-012 dormant surfaces (rendered constants; no write path).
const CLOUD_SYNC_STATUS = { enabled: false, greyed: true, copyKey: 'settings.cloudSync.coming', infoIssue: '#4' };
const HEVY_IMPORT_ENTRY = { enabled: false, blockedByTicket: '#30', copyKey: 'settings.dataSync.importHevy' };

// BR-006 validation mirror. Returns an error code or null (lawful).
function validateBodyMetric({ kind, label, value, unit }) {
  if (!['bodyWeight', 'bodyFat', 'measurement'].includes(kind)) return 'invalidKind';
  if (kind === 'measurement' && !(label ?? '').trim()) return 'measurementRequiresLabel';
  if (kind === 'bodyWeight' && unit !== 'kg' && unit !== 'lb') return 'invalidUnit';
  if (kind === 'bodyFat' && unit !== 'pct') return 'invalidUnit';
  if (kind === 'measurement' && !(unit ?? '').trim()) return 'invalidUnit';
  if (!Number.isFinite(value) || value <= 0) return 'invalidValue';
  if (kind === 'bodyFat' && value > 100) return 'invalidValue';
  return null;
}

// BR-013 keyed copy mirrors (exact strings from §6).
const EMPTY_STATE_COPY = {
  'home.empty_title': 'No routines yet',
  'home.empty_sub': 'Routines are your gym days. Create one and your next workout is one tap to start.',
  'home.empty_cta': 'Create your first routine',
  'home.streak_label': '{n}-day streak',
  'home.startEmpty_cta': 'Start empty',
  'activeWorkout.emptyList_line': 'No sets yet',
  'activeWorkout.addExercise_cta': '+ Add exercise',
  'activeWorkout.startEmpty_help': 'Add an exercise to start logging',
  'history.empty_title': 'No sessions yet',
  'history.empty_sub': 'Your gym visits will live here.',
  'history.empty_cta': 'Start a workout',
  'analytics.empty_title': 'Nothing to graph yet',
  'analytics.empty_sub': 'Log 3 sessions to start seeing trends.',
  'analytics.empty_cta': 'Log your first session',
  'analytics.hint_body': 'Every workout builds your stats.',
  'picker.search_empty_title': 'No matches',
  'picker.search_empty_sub': 'Check spelling or create it custom.',
  'picker.createCustom_cta': 'Create custom exercise',
  'picker.browse_hint': 'Or scroll to browse',
};
const FOUNDATION_DB_COPY = {
  'foundation.db.fatalTitle': 'Storage unavailable',
  'foundation.db.fatalBody': "Moore's local database can't be opened. Your training data may be at risk. Export a backup from Settings if you can, then reinstall the app.",
  'foundation.db.fatalAction': 'Export backup',
  'foundation.db.migrationFailedTitle': 'Update failed',
  'foundation.db.migrationFailedBody': "This update requires a database change that didn't complete. Don't delete the app — export your data and contact support.",
  'foundation.db.migrationFailedAction': 'Contact support',
  'foundation.db.corrupted': 'The database file is damaged. Restore from your last backup.',
  'foundation.db.unknownError': 'Something went wrong with local storage. Try again.',
};
const SETTINGS_COPY = {
  'settings.title': 'Settings',
  'settings.units.title': 'Units',
  'settings.units.weight': 'Weight unit',
  'settings.restDefaults.title': 'Rest defaults',
  'settings.restDefaults.compound': 'Compound lifts',
  'settings.restDefaults.isolation': 'Isolation',
  'settings.restDefaults.value': '{n}s',
  'settings.bodyMetrics.title': 'Body metrics',
  'settings.bodyMetrics.addCta': 'Add entry',
  'settings.bodyMetrics.empty': 'No entries yet',
  'settings.bodyMetrics.trendTitle': 'Trend',
  'settings.dataSync.title': 'Data & sync',
  'settings.dataSync.exportCta': 'Export backup',
  'settings.dataSync.exportedToast': 'Backup saved: {fileName}',
  'settings.dataSync.importHevy': 'Import from Hevy',
  'settings.dataSync.importHevyBlocked': 'Available after import ships',
  'settings.cloudSync.title': 'Cloud sync',
  'settings.cloudSync.coming': 'Coming after self-validation gate',
  'settings.tombstones.title': 'Deleted custom exercises',
  'settings.tombstones.restoreCta': 'Restore',
  'settings.tombstones.empty': 'Nothing deleted',
};
const COPY_TABLES = { emptyStateCopy: EMPTY_STATE_COPY, foundationDbCopy: FOUNDATION_DB_COPY, settingsCopy: SETTINGS_COPY };

// ---------------------------------------------------------------------------
// JS mirror of SettingsDAO seam-2 behavior (better-sqlite3 stands in for GRDB).
// ---------------------------------------------------------------------------
const parseIntOrNull = (s) => { const n = parseInt(s, 10); return Number.isNaN(n) ? null : n; };

function fetchSettings(db) {
  const get = (k) => db.prepare('SELECT value FROM app_setting WHERE key = ?').get(k)?.value;
  const wu = get('weightUnit');
  return {
    weightUnit: wu === 'kg' || wu === 'lb' ? wu : 'kg',                      // BR-014 fallback
    defaultRestCompoundSec: parseIntOrNull(get('defaultRestCompoundSec')) ?? 180,
    defaultRestIsolationSec: parseIntOrNull(get('defaultRestIsolationSec')) ?? 90,
  };
}
function upsertSetting(db, key, value, at) {
  db.prepare(`
    INSERT INTO app_setting (key, value, updatedAt) VALUES (?, ?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
  `).run(key, String(value), at);
}
const setWeightUnit = (db, unit, at) => upsertSetting(db, 'weightUnit', unit, at);   // BR-001: the ONLY write
function updateRestDefaults(db, { compoundSec, isolationSec }, at) {
  if (compoundSec != null) upsertSetting(db, 'defaultRestCompoundSec', compoundSec, at);
  if (isolationSec != null) upsertSetting(db, 'defaultRestIsolationSec', isolationSec, at);
}

function addBodyMetric(db, m) {
  const err = validateBodyMetric(m);
  if (err) return { error: err };
  const id = m.id ?? randomUUID();
  db.prepare(`
    INSERT INTO body_metric (id, kind, label, value, unit, recordedAt, createdAt, updatedAt, deletedAt)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
  `).run(id, m.kind, m.kind === 'measurement' ? m.label ?? null : null, m.value, m.unit, m.recordedAt, m.at, m.at);
  return { id };
}
function listBodyMetrics(db, kind) {
  const rows = kind != null
    ? db.prepare('SELECT * FROM body_metric WHERE deletedAt IS NULL AND kind = ? ORDER BY recordedAt DESC, createdAt DESC').all(kind)
    : db.prepare('SELECT * FROM body_metric WHERE deletedAt IS NULL ORDER BY recordedAt DESC, createdAt DESC').all();
  return rows;
}
const listTombstonedCustomExercises = (db) =>
  db.prepare(`SELECT id, name, exerciseType, isCustom, deletedAt FROM exercise WHERE deletedAt IS NOT NULL`).all()
    .map((r) => ({ ...r }));
function restoreExercise(db, id, at) {
  db.prepare('UPDATE exercise SET deletedAt = NULL, updatedAt = ? WHERE id = ? AND deletedAt IS NOT NULL').run(at, id);
}

function tableNames(db) {
  return db.prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`).all().map((r) => r.name);
}
function hasDeletedAtColumn(db, table) {
  return db.prepare(`PRAGMA table_info("${table}")`).all().some((c) => c.name === 'deletedAt');
}
function exportSelectDumps(db) {
  return tableNames(db).map((table) => {
    const rowCount = db.prepare(`SELECT COUNT(*) AS n FROM "${table}"`).get().n;
    const tombstoneCount = hasDeletedAtColumn(db, table)
      ? db.prepare(`SELECT COUNT(*) AS n FROM "${table}" WHERE deletedAt IS NOT NULL`).get().n
      : 0;
    return { table, rowCount, tombstoneCount };
  });
}

// Deterministic logical-content digest for the round-trip hash assertion.
function contentHash(db) {
  const parts = [];
  for (const t of db.prepare(`SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`).all()) {
    parts.push(`TABLE ${t.name}\n${t.sql}`);
    for (const row of db.prepare(`SELECT * FROM "${t.name}" ORDER BY rowid`).all()) parts.push(JSON.stringify(row));
  }
  for (const i of db.prepare(`SELECT name, sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY name`).all()) {
    parts.push(`INDEX ${i.name}\n${i.sql}`);
  }
  return createHash('sha256').update(parts.join('\n')).digest('hex');
}
function schemaShape(db) {
  const shape = {};
  for (const t of tableNames(db)) shape[t] = db.prepare(`PRAGMA table_info("${t}")`).all().map((c) => c.name).sort();
  return shape;
}

// ---------------------------------------------------------------------------
// DB plumbing
// ---------------------------------------------------------------------------
function newDbFull() {
  const db = new Database(':memory:');
  for (const m of MIGRATIONS) db.exec(readFileSync(m, 'utf8'));
  return db;
}
function newDbStaged(fixture) {
  // Apply everything up to 0009, seed legacy-shape rows, THEN apply 0009 —
  // proving the rebuild remap + preservation on live data.
  const db = new Database(':memory:');
  for (const m of MIGRATIONS_PRE_0009) db.exec(readFileSync(m, 'utf8'));
  const ibm = db.prepare(`INSERT INTO body_metric (id, kind, value, unit, recordedAt, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)`);
  for (const m of fixture.legacySeed?.bodyMetrics ?? []) ibm.run(m.id, m.kind, m.value, m.unit, m.recordedAt, m.createdAt, m.updatedAt);
  db.exec(readFileSync(MIG_0009, 'utf8'));
  return db;
}

function seedFixture(db, fx) {
  const s = fx.seed ?? {};
  const now = SEED_NOW;
  for (const r of s.folders ?? [])
    db.prepare(`INSERT INTO folder (id, name, createdAt, updatedAt, deletedAt) VALUES (?, ?, ?, ?, ?)`).run(r.id, r.name, now, now, r.deletedAt ?? null);
  for (const r of s.exercises ?? [])
    db.prepare(`INSERT INTO exercise (id, name, exerciseType, isCustom, createdAt, updatedAt, deletedAt) VALUES (?, ?, ?, ?, ?, ?, ?)`).run(r.id, r.name, r.exerciseType, r.isCustom ?? 0, now, now, r.deletedAt ?? null);
  for (const r of s.routines ?? [])
    db.prepare(`INSERT INTO routine (id, folderId, name, sortOrder, createdAt, updatedAt, deletedAt) VALUES (?, ?, ?, ?, ?, ?, ?)`).run(r.id, r.folderId ?? null, r.name, r.sortOrder ?? 0, now, now, r.deletedAt ?? null);
  for (const r of s.plannedSets ?? [])
    db.prepare(`INSERT INTO planned_set (id, routineId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration, createdAt, updatedAt, deletedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(r.id, r.routineId, r.exerciseId, r.sortOrder ?? 0, r.plannedWeight ?? null, r.plannedReps ?? null, r.plannedDuration ?? null, now, now, r.deletedAt ?? null);
  for (const r of s.sessions ?? [])
    db.prepare(`INSERT INTO workout_session (id, startedAt, endedAt, createdAt, updatedAt, deletedAt) VALUES (?, ?, ?, ?, ?, ?)`).run(r.id, r.startedAt, r.endedAt ?? null, now, now, r.deletedAt ?? null);
  let ord = 0;
  for (const r of s.completedSets ?? [])
    db.prepare(`
      INSERT INTO completed_set (id, sessionId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration, actualWeight, actualReps, actualDuration, status, completedAt, createdAt, updatedAt, deletedAt)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(r.id, r.sessionId, r.exerciseId, ord++, r.plannedWeight ?? null, r.plannedReps ?? null, r.plannedDuration ?? null, r.actualWeight ?? null, r.actualReps ?? null, r.actualDuration ?? null, r.status, r.completedAt ?? null, now, now, r.deletedAt ?? null);
  for (const r of s.personalRecords ?? [])
    db.prepare(`INSERT INTO personal_record (id, exerciseId, sessionId, setId, kind, value, achievedAt, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(r.id, r.exerciseId, r.sessionId, r.setId ?? null, r.kind, r.value, r.achievedAt, now, now);
  for (const r of s.bodyMetrics ?? [])
    db.prepare(`INSERT INTO body_metric (id, kind, label, value, unit, recordedAt, createdAt, updatedAt, deletedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(r.id, r.kind, r.label ?? null, r.value, r.unit, r.recordedAt, now, now, r.deletedAt ?? null);
  for (const r of s.progressionSchemes ?? [])
    db.prepare(`INSERT INTO progression_scheme (id, routineId, exerciseId, scheme, incrementValue, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)`)
      .run(r.id, r.routineId, r.exerciseId, r.scheme, r.incrementValue ?? null, now, now);
  if (s.settings?.weightUnit) upsertSetting(db, 'weightUnit', s.settings.weightUnit, now);
}

// ---------------------------------------------------------------------------
// Round-trip export (seam-2 AC: backup DB hash matches original)
// ---------------------------------------------------------------------------
async function runExportRoundTrip(db, expect, label) {
  const tmpFile = join(tmpdir(), `moore-roundtrip-${randomUUID()}${BACKUP_SUFFIX}`);
  const fresh = newDbFull();
  try {
    await db.backup(tmpFile);                                   // full SQLite file copy
    const copy = new Database(tmpFile, { fileMustExist: true });
    try {
      // 1. Per-table row counts match — tombstones included (INV-ST3).
      let countsOk = true;
      for (const table of tableNames(db)) {
        const a = db.prepare(`SELECT COUNT(*) AS n FROM "${table}"`).get().n;
        const b = copy.prepare(`SELECT COUNT(*) AS n FROM "${table}"`).get().n;
        if (a !== b) { countsOk = false; fail(`${label}.rowCounts.${table}: original=${a} copy=${b}`); }
      }
      countsOk ? pass(`${label}.rowCountsMatch`) : null;

      // 2. Logical content hash matches (the seam-2 hash assertion).
      const hOrig = contentHash(db), hCopy = contentHash(copy);
      hOrig === hCopy ? pass(`${label}.contentHashMatches`) : fail(`${label}.contentHash: ${hCopy} != ${hOrig}`);

      // 3. Integrity.
      const integrity = copy.prepare('PRAGMA integrity_check').get()?.integrity_check;
      integrity === 'ok' ? pass(`${label}.integrityOk`) : fail(`${label}.integrity: ${integrity}`);

      // 4. Imports cleanly back into the same app version: the copy's schema
      //    shape equals a freshly-migrated DB's shape, table for table.
      const shapeCopy = schemaShape(copy), shapeFresh = schemaShape(fresh);
      deepEq(shapeCopy, shapeFresh, `${label}.schemaShapeMatchesFreshDb`);

      // 5. Tombstones + NULL plannedX survived the trip.
      if (expect.tombstonedExerciseSurvives) {
        const row = copy.prepare('SELECT deletedAt FROM exercise WHERE id = ?').get(expect.tombstonedExerciseSurvives);
        row?.deletedAt != null ? pass(`${label}.tombstonedExerciseSurvives`) : fail(`${label}.tombstonedExerciseSurvives: row missing or live`);
      }
      if (expect.tombstonedSetSurvives) {
        const row = copy.prepare('SELECT deletedAt, plannedWeight FROM completed_set WHERE id = ?').get(expect.tombstonedSetSurvives);
        row?.deletedAt != null ? pass(`${label}.tombstonedSetSurvives`) : fail(`${label}.tombstonedSetSurvives: row missing or live`);
        if (expect.nullPlannedColumnsSurvive === expect.tombstonedSetSurvives) {
          row.plannedWeight === null ? pass(`${label}.nullPlannedColumnsSurvive`) : fail(`${label}.nullPlannedColumnsSurvive: plannedWeight=${row.plannedWeight}`);
        }
      }
      if (expect.tombstonedMetricSurvives) {
        const row = copy.prepare('SELECT deletedAt FROM body_metric WHERE id = ?').get(expect.tombstonedMetricSurvives);
        row?.deletedAt != null ? pass(`${label}.tombstonedMetricSurvives`) : fail(`${label}.tombstonedMetricSurvives: row missing or live`);
      }
    } finally {
      copy.close();
    }
  } finally {
    fresh.close();
    try { unlinkSync(tmpFile); } catch { /* best effort */ }
  }
}

// ---------------------------------------------------------------------------
// Step executor
// ---------------------------------------------------------------------------
function runSteps(db, fixture, vector) {
  const state = { snapshots: {}, priorSettingUpdatedAt: {} };
  for (const [i, step] of (vector.steps ?? []).entries()) {
    const id = `${fixture.fixture}.${vector.id}.step${i + 1}(${step.do})`;
    switch (step.do) {
      // ---- Engine mirror steps (pure) ----
      case 'kgToLb': approx(kgToLb(step.kg), step.expect, id); break;
      case 'lbToKg': approx(lbToKg(step.lb), step.expect, id); break;
      case 'roundDisplay': approx(roundDisplay(step.value), step.expect, id); break;
      case 'roundStorage': approx(roundStorage(step.value), step.expect, id); break;
      case 'displayString': eq(displayString(step.rawKg, step.unit), step.expect, id); break;
      case 'entryToStorage': approx(entryToStorage(step.entered, step.unit), step.expectKg, id); break;

      case 'cloudSyncStatus': deepEq(CLOUD_SYNC_STATUS, step.expect, id); break;
      case 'hevyImportEntry': deepEq(HEVY_IMPORT_ENTRY, step.expect, id); break;

      case 'assertCopyTable': deepEq(COPY_TABLES[step.table], step.expect, id); break;
      case 'assertCopyTableComplete': {
        const table = COPY_TABLES[step.table];
        let ok = true;
        for (const key of step.keys) {
          if (typeof table[key] !== 'string' || table[key].length === 0) { ok = false; fail(`${id}: key ${key} missing or empty`); }
        }
        if (ok) pass(id);
        break;
      }
      case 'assertCopyValue': eq(COPY_TABLES[step.table][step.key], step.expect, id); break;

      // ---- Settings persistence ----
      case 'fetchSettings': deepEq(fetchSettings(db), step.expect, id); break;
      case 'setWeightUnit': setWeightUnit(db, step.unit, step.at); pass(id); break;
      case 'updateRestDefaults': {
        for (const [key, v] of [['defaultRestCompoundSec', step.compoundSec], ['defaultRestIsolationSec', step.isolationSec]]) {
          if (v != null) state.priorSettingUpdatedAt[key] = db.prepare('SELECT updatedAt FROM app_setting WHERE key = ?').get(key)?.updatedAt ?? null;
        }
        updateRestDefaults(db, step, step.at);
        if (step.expect) deepEq(fetchSettings(db), step.expect, id); else pass(id);
        break;
      }
      case 'assertSettingUpdatedAtBumped': {
        const after = db.prepare('SELECT updatedAt FROM app_setting WHERE key = ?').get(step.key)?.updatedAt;
        const before = state.priorSettingUpdatedAt[step.key];
        after != null && after !== before ? pass(id) : fail(`${id}: updatedAt not bumped (before=${before} after=${after})`);
        break;
      }
      case 'assertSettingsRowCount':
        eq(db.prepare('SELECT COUNT(*) AS n FROM app_setting').get().n, step.expect, id);
        break;
      case 'assertSettingsRowCountForKeys': {
        const n = db.prepare(`SELECT COUNT(*) AS n FROM app_setting WHERE key IN (${step.keys.map(() => '?').join(',')})`).get(...step.keys).n;
        eq(n, step.expect, id);
        break;
      }
      case 'reapplyRestSeed': db.exec(REST_SEED_SQL); pass(id); break;

      // ---- Body metrics CRUD ----
      case 'addBodyMetric': {
        const res = addBodyMetric(db, step);
        if (step.expectError) {
          res.error === step.expectError ? pass(id) : fail(`${id}: expected error ${step.expectError}, got ${JSON.stringify(res)}`);
        } else {
          res.error == null ? pass(id) : fail(`${id}: unexpected error ${res.error}`);
        }
        break;
      }
      case 'listBodyMetrics': {
        const rows = listBodyMetrics(db, step.kind ?? null).map((r) => {
          const out = { kind: r.kind, value: r.value, unit: r.unit, recordedAt: r.recordedAt };
          if (r.label != null) out.label = r.label;
          return out;
        });
        deepEq(rows, step.expect, id);
        break;
      }
      case 'updateBodyMetric': {
        const kind = db.prepare('SELECT kind FROM body_metric WHERE id = ? AND deletedAt IS NULL').get(step.id)?.kind;
        const err = validateBodyMetric({ kind, label: step.label, value: step.value, unit: step.unit });
        if (err) { fail(`${id}: validation ${err}`); break; }
        db.prepare('UPDATE body_metric SET value = ?, unit = ?, label = ?, recordedAt = ?, updatedAt = ? WHERE id = ? AND deletedAt IS NULL')
          .run(step.value, step.unit, kind === 'measurement' ? step.label ?? null : null, step.recordedAt, step.at, step.id);
        pass(id);
        break;
      }
      case 'softDeleteBodyMetric':
        db.prepare('UPDATE body_metric SET deletedAt = ?, updatedAt = ? WHERE id = ? AND deletedAt IS NULL').run(step.at, step.at, step.id);
        pass(id);
        break;
      case 'assertBodyMetricUpdatedAt':
        eq(db.prepare('SELECT updatedAt FROM body_metric WHERE id = ?').get(step.id)?.updatedAt, step.expect, id);
        break;
      case 'assertBodyMetricRawRow': {
        const row = db.prepare('SELECT * FROM body_metric WHERE id = ?').get(step.id);
        row && row.deletedAt === step.expectDeletedAt ? pass(id) : fail(`${id}: row=${JSON.stringify(row)}`);
        break;
      }
      case 'assertBodyMetricRawCount':
        eq(db.prepare('SELECT COUNT(*) AS n FROM body_metric').get().n, step.expect, id);
        break;
      case 'assertBodyMetricRow': {
        const row = db.prepare('SELECT * FROM body_metric WHERE id = ?').get(step.id);
        const got = row ? { kind: row.kind, label: row.label ?? null, value: row.value, unit: row.unit } : null;
        deepEq(got, step.expect, id);
        break;
      }
      case 'assertBodyMetricColumns':
        deepEq(db.prepare('PRAGMA table_info(body_metric)').all().map((c) => c.name), step.expect, id);
        break;
      case 'insertRawExpectCheckFailure': {
        let threw = false;
        try {
          db.prepare(`INSERT INTO body_metric (id, kind, value, unit, recordedAt, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, 't', 't')`)
            .run(randomUUID(), step.kind, step.value, step.unit, step.recordedAt);
        } catch { threw = true; }
        threw ? pass(id) : fail(`${id}: kind='${step.kind}' must violate CHECK post-0009`);
        break;
      }
      case 'assertTableExists': {
        const t = db.prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name = ?`).get(step.table);
        t ? pass(id) : fail(`${id}: table ${step.table} missing`);
        break;
      }
      case 'assertLegacyRawKind':
        eq(db.prepare('SELECT kind FROM body_metric__legacy_0001 WHERE id = ?').get(step.id)?.kind, step.expect, id);
        break;

      // ---- Tombstone management ----
      case 'listTombstonedExercises': {
        const rows = tombstonedCustomExercises(listTombstonedCustomExercises(db))
          .map((r) => ({ id: r.id, name: r.name, deletedAt: r.deletedAt }));
        deepEq(rows, step.expect, id);
        break;
      }
      case 'restoreExercise': restoreExercise(db, step.id, step.at); pass(id); break;
      case 'assertExerciseLive': {
        const row = db.prepare('SELECT deletedAt, updatedAt FROM exercise WHERE id = ?').get(step.id);
        row && row.deletedAt === null && (step.expectUpdatedAt == null || row.updatedAt === step.expectUpdatedAt)
          ? pass(id) : fail(`${id}: row=${JSON.stringify(row)}`);
        break;
      }
      case 'assertExerciseStillTombstoned': {
        const row = db.prepare('SELECT deletedAt FROM exercise WHERE id = ?').get(step.id);
        row?.deletedAt != null ? pass(id) : fail(`${id}: row=${JSON.stringify(row)}`);
        break;
      }
      case 'assertExerciseUntouched': {
        // Restore on a live row is a no-op: still live, updatedAt unchanged.
        const row = db.prepare('SELECT deletedAt, updatedAt FROM exercise WHERE id = ?').get(step.id);
        row && row.deletedAt === null && row.updatedAt === SEED_NOW ? pass(id) : fail(`${id}: row=${JSON.stringify(row)}`);
        break;
      }

      // ---- Display pipelines (read settings live) ----
      case 'displayStoredWeight': {
        const settings = fetchSettings(db);
        const raw = db.prepare(`SELECT ${step.column} AS w FROM completed_set WHERE id = ?`).get(step.setId)?.w;
        eq(raw == null ? null : displayString(raw, settings.weightUnit), step.expect, id);
        break;
      }
      case 'displayBodyMetricRow': {
        const settings = fetchSettings(db);
        const row = db.prepare('SELECT value, unit FROM body_metric WHERE id = ?').get(step.metricId);
        eq(row ? displayBodyMetricString(row.value, row.unit, settings.weightUnit) : null, step.expect, id);
        break;
      }

      // ---- Snapshots / display-only proof ----
      case 'snapshotTable':
        state.snapshots[step.table] = JSON.stringify(db.prepare(`SELECT * FROM "${step.table}" ORDER BY rowid`).all());
        pass(id);
        break;
      case 'assertTableUnchanged': {
        const now = JSON.stringify(db.prepare(`SELECT * FROM "${step.table}" ORDER BY rowid`).all());
        state.snapshots[step.table] === now ? pass(id) : fail(`${id}: ${step.table} rows changed (INV violation)`);
        break;
      }
      case 'assertSessionCount':
        eq(db.prepare('SELECT COUNT(*) AS n FROM workout_session').get().n, step.expect, id);
        break;

      // ---- Export ----
      case 'buildManifest': {
        const exportedAt = vector.exportedAt ?? fixture.exportedAt;
        const manifest = buildExportManifest(exportSelectDumps(db), exportedAt);
        deepEq(manifest, { exportedAt, ...step.expect }, id);
        break;
      }
      case 'assertLegacyTablesPresent': {
        let ok = true;
        for (const t of step.expect) {
          const row = db.prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name = ?`).get(t);
          if (!row) { ok = false; fail(`${id}: legacy table ${t} missing`); }
        }
        if (ok) pass(id);
        break;
      }
      case 'assertPlannedColumnsPresent': {
        const cols = db.prepare(`PRAGMA table_info("${step.table}")`).all().map((c) => c.name);
        const missing = step.columns.filter((c) => !cols.includes(c));
        missing.length === 0 ? pass(id) : fail(`${id}: missing columns ${missing.join(', ')}`);
        break;
      }
      case 'exportRoundTrip':
        // Handled by the async runner (needs await on db.backup).
        break;

      default:
        fail(`${id}: unknown step ${step.do}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Schema sanity across the full chain
// ---------------------------------------------------------------------------
function schemaSanity() {
  const db = newDbFull();
  try {
    for (const t of ['app_setting', 'body_metric', 'body_metric__legacy_0001']) {
      const row = db.prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name = ?`).get(t);
      row ? pass(`schema.${t}.exists`) : fail(`schema: missing table ${t}`);
    }
    const cols = db.prepare('PRAGMA table_info(body_metric)').all().map((c) => c.name);
    cols.includes('label') ? pass('schema.body_metric.label.exists') : fail('schema: body_metric.label missing');
    // Closed vocabulary: 'measurement' accepted, legacy 'weight' rejected.
    db.prepare(`INSERT INTO body_metric (id, kind, label, value, unit, recordedAt, createdAt, updatedAt) VALUES ('sanity-m','measurement','Waist',84,'cm','t','t','t')`).run();
    pass('schema.body_metric.measurement.accepted');
    let threw = false;
    try {
      db.prepare(`INSERT INTO body_metric (id, kind, value, unit, recordedAt, createdAt, updatedAt) VALUES ('sanity-w','weight',80,'kg','t','t','t')`).run();
    } catch { threw = true; }
    threw ? pass('schema.body_metric.legacy-kind-rejected') : fail('schema: kind=weight must violate CHECK post-0009');
  } finally {
    db.close();
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
async function main() {
  schemaSanity();

  const files = readdirSync(FIXT).filter((f) => f.endsWith('.json')).sort();
  for (const fname of files) {
    const fixture = JSON.parse(readFileSync(join(FIXT, fname), 'utf8'));
    console.log(`\n-- ${fname}: ${fixture.cites ?? ''}`);
    // Fresh DB per vector: each vector is a self-contained acceptance scenario
    // (fixtures declare their own seed; vectors never rely on prior vectors).
    for (const vector of fixture.vectors ?? []) {
      const db = fixture.migrationMode === 'staged' ? newDbStaged(fixture) : newDbFull();
      try {
        if (fixture.migrationMode !== 'staged') seedFixture(db, fixture);
        runSteps(db, fixture, vector);
        // Async export vector (seam-2 round-trip).
        for (const [i, step] of (vector.steps ?? []).entries()) {
          if (step.do === 'exportRoundTrip') {
            await runExportRoundTrip(db, step.expect ?? {}, `${fixture.fixture}.${vector.id}.step${i + 1}(exportRoundTrip)`);
          }
        }
      } finally {
        db.close();
      }
    }
  }

  console.log('');
  if (failures === 0) { console.log(`ALL SETTINGS FIXTURES PASS (${passes} checks)`); process.exit(0); }
  console.error(`${failures} check(s) failed`);
  process.exit(1);
}

main().catch((e) => { console.error(e); process.exit(1); });
