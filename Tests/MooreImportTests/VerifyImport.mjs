// Seam-1/seam-2 verifier for SC-import@1.0.0 (ticket #30).
// JS mirror of Sources/MooreImport/HevyCsvParser.swift + HevyImportEngine.swift
// + HevyImportDAO.swift; PR re-derivation mirrors SC-prs@1.0.0 BR-009 exactly as
// VerifyRecords.mjs does. Fresh in-memory DB per vector; migrations chain
// 0001,0002,0003,0005,0006,0007_rest_fields,0008 (0003 carries the importKey
// columns + UNIQUE partial index this contract dedupes on).
//
// Usage: node Tests/MooreImportTests/VerifyImport.mjs

import Database from 'better-sqlite3';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const worktreeRoot = join(here, '..', '..');
const FIXT = join(here, 'Fixtures');
const SEED = join(worktreeRoot, 'Sources', 'MooreExercises', 'Seed', 'builtin-library.json');

const MIGRATIONS = [
  'Sources/MooreFoundation/Migrations/0001_core.sql',
  'Sources/MooreFoundation/Migrations/0002_warmup_progression.sql',
  'Sources/MooreFoundation/Migrations/0003_import_columns.sql',
  'Sources/MooreRoutines/Migrations/0005_routines_folders.sql',
  'Sources/MooreRoutines/Migrations/0006_routines_session_link.sql',
  'Sources/MooreRest/Migrations/0007_rest_fields.sql',
  'Sources/MooreRecords/Migrations/0008_personal_records.sql',
].map((p) => join(worktreeRoot, ...p.split('/')));

const NOW = '2026-08-12T12:00:00Z';
const UNTITLED = 'Imported workout';              // §6 hevyImport.untitledSession
const LB_PER_KG = 2.20462;                        // BR-010
const KG_PER_LB = 1 / 2.20462;

let failures = 0, passes = 0;
const fail = (m) => { console.error(`FAIL: ${m}`); failures += 1; };
const pass = (m) => { console.log(`PASS: ${m}`); passes += 1; };
const eq = (a, b, label) => (a === b ? pass(label) : fail(`${label}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`));
const approx = (a, b, label) => (a != null && Math.abs(a - b) < 1e-9 ? pass(label) : fail(`${label}: expected ~${b}, got ${a}`));

// ---- name handling (SC-exercises BR-001 parity) ----
const normalize = (s) => s.toLowerCase().trim().split(/\s+/).filter(Boolean).join(' ');
const displayForm = (s) => s.trim().split(/\s+/).filter(Boolean).join(' ');
const normalizeHeader = (s) => s.toLowerCase().trim().split(/\s+/).filter(Boolean).join('_');
const unescapeHevyNewlines = (s) => s.replace(/\\n/g, '\n');

// ---- RFC 4180 parser mirror (HevyCsvParser.swift, BR-001) ----
function parseRecords(text) {
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);   // BOM stripped
  const records = [];
  let record = [];
  let field = '';
  let inQuotes = false;
  let recordIndex = 1;
  let sawContent = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i += 1; continue; }
        inQuotes = false; continue;
      }
      field += c; continue;
    }
    if (c === '"' && field === '') { inQuotes = true; sawContent = true; continue; }
    if (c === ',') { record.push(field); field = ''; sawContent = true; continue; }
    if (c === '\r' || c === '\n') {
      if (c === '\r' && text[i + 1] === '\n') i += 1;
      record.push(field); records.push(record);
      record = []; field = ''; sawContent = false; recordIndex += 1;
      continue;
    }
    field += c; sawContent = true;
  }
  if (inQuotes) throw { code: 'csvMalformed', message: `unterminatedQuote at record ${recordIndex}` };
  if (field !== '' || record.length > 0 || sawContent) { record.push(field); records.push(record); }
  return records;
}

// ---- datetime mirror (BR-004) ----
const MONTH_IDX = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 };
const daysInMonth = (m, y) => (m === 2 ? ((y % 4 === 0 && y % 100 !== 0) || y % 400 === 0 ? 29 : 28) : [1, 3, 5, 7, 8, 10, 12].includes(m) ? 31 : 30);
const DATE_RE = /^\s*(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s*,?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*$/;

function parseHevyDateTime(raw, offsetMinutes) {
  const m = DATE_RE.exec(raw);
  if (!m) return null;
  const day = +m[1], mon = MONTH_IDX[m[2].toLowerCase()], year = +m[3];
  const hour = +m[4], minute = +m[5], second = m[6] != null ? +m[6] : 0;
  if (mon == null) return null;
  if (year < 1900 || year > 2100) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;
  if (day < 1 || day > daysInMonth(mon, year)) return null;
  return Date.UTC(year, mon - 1, day, hour, minute, second) - offsetMinutes * 60000;
}

const pad2 = (n) => String(n).padStart(2, '0');
function isoUTC(ms) {
  const d = new Date(ms);
  return `${d.getUTCFullYear()}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())}T${pad2(d.getUTCHours())}:${pad2(d.getUTCMinutes())}:${pad2(d.getUTCSeconds())}Z`;
}
const isoFromKey = (key) => key.slice(key.lastIndexOf('|') + 1);

// ---- numeric validation (strict, mirrors Swift Int/Double parse failures) ----
const INT_RE = /^[+-]?\d+$/;
const DOUBLE_RE = /^[+-]?(\d+(\.\d*)?|\.\d+)$/;

// ---- exercise matching mirror (BR-009) ----
const EQUIPMENT_MAP = {
  barbell: 'barbell', dumbbell: 'dumbbell', cable: 'cable', machine: 'machine',
  bodyweight: 'bodyweight', 'smith machine': 'smith', plate: 'plate', band: 'band',
  kettlebell: 'kettlebell', 'ez bar': 'ezBar', 'trap bar': 'trapBar',
  'medicine ball': 'medicineBall', sled: 'sled',
};
const equipmentSlugFromHevy = (label) => EQUIPMENT_MAP[label.toLowerCase()] ?? 'other';

function stripTrailingParenthetical(norm) {
  const open = norm.lastIndexOf('(');
  const close = norm.lastIndexOf(')');
  if (open < 0 || close < 0 || open >= close) return null;
  if (norm.slice(close + 1).trim() !== '') return null;
  const base = norm.slice(0, open).trim();
  if (base === '') return null;
  return { base, label: norm.slice(open + 1, close) };
}

const sortCandidates = (rows) => [...rows].sort((a, b) => {
  if (a.isCustom !== b.isCustom) return a.isCustom ? 1 : -1;   // built-ins first
  if (a.name !== b.name) return a.name < b.name ? -1 : 1;
  return a.id < b.id ? -1 : 1;
});

function matchLibrary(normEx, library) {
  const primary = library.filter((r) => r.nameNormalized === normEx);
  if (primary.length) return sortCandidates(primary)[0];
  const stripped = stripTrailingParenthetical(normEx);
  if (!stripped) return null;
  const wanted = equipmentSlugFromHevy(stripped.label);
  const secondary = library.filter((r) =>
    r.nameNormalized === stripped.base && (r.equipmentSlug == null || r.equipmentSlug === wanted));
  return secondary.length ? sortCandidates(secondary)[0] : null;
}

// ---- engine mirror (HevyImportEngine.buildPlan, BR-002…BR-014) ----
const RECOGNIZED = new Set([
  'title', 'start_time', 'end_time', 'description', 'exercise_title',
  'superset_id', 'exercise_notes', 'set_index', 'set_type',
  'weight_kg', 'weight_lbs', 'reps', 'distance_km', 'distance_miles',
  'duration_seconds', 'rpe',
]);

const notHevyExport = (message) => ({ code: 'notHevyExport', message });

function buildPlan(csvText, library, options) {
  const tzOffset = options.timezoneOffsetMinutes ?? 0;
  let records;
  try { records = parseRecords(csvText); }
  catch (e) { throw { code: 'csvMalformed', message: e.message ?? String(e) }; }
  if (!records.length) throw notHevyExport('empty file — no header record');

  const columnIndex = {};
  const warnings = [];
  records[0].forEach((raw, idx) => {
    const norm = normalizeHeader(raw);
    if (!RECOGNIZED.has(norm)) return;
    if (norm in columnIndex) warnings.push(`duplicate header '${norm}' — first occurrence wins`);
    else columnIndex[norm] = idx;
  });
  if (!('start_time' in columnIndex) || !('exercise_title' in columnIndex))
    throw notHevyExport('missing required header(s): start_time / exercise_title');

  const hasKg = 'weight_kg' in columnIndex, hasLb = 'weight_lbs' in columnIndex;
  let declaredUnit = null;
  if (hasKg && hasLb) { declaredUnit = 'kg'; warnings.push('both weight_kg and weight_lbs present — kg wins'); }
  else if (hasKg) declaredUnit = 'kg';
  else if (hasLb) declaredUnit = 'lb';

  const cell = (record, col) =>
    (col in columnIndex && columnIndex[col] < record.length) ? record[columnIndex[col]] : '';

  const counts = {
    dataRows: records.length - 1, emptyRowsSkipped: 0, duplicatesCollapsed: 0,
    sessionsFound: 0, setsImported: 0, exercisesMatched: 0, sessionsAlreadyImported: 0,
    cardioRowsSkipped: 0, foldedSetTypes: 0, quarantinedCount: 0,
    metadataDropped: { rpe: 0, exerciseNotes: 0, supersetId: 0 },
  };
  const quarantined = [];
  const validRows = [];

  records.slice(1).forEach((record, index) => {
    const rowNumber = index + 1;
    if (record.every((f) => f.trim() === '')) { counts.emptyRowsSkipped += 1; return; }
    const title = cell(record, 'title').trim();
    const startRaw = cell(record, 'start_time').trim();
    const exerciseTitle = cell(record, 'exercise_title').trim();
    const setIndexRaw = cell(record, 'set_index').trim();
    const setTypeRaw = cell(record, 'set_type').trim();
    const weightKgRaw = cell(record, 'weight_kg').trim();
    const weightLbsRaw = cell(record, 'weight_lbs').trim();
    const repsRaw = cell(record, 'reps').trim();
    const distanceKmRaw = cell(record, 'distance_km').trim();
    const distanceMilesRaw = cell(record, 'distance_miles').trim();
    const durationRaw = cell(record, 'duration_seconds').trim();
    const rpeRaw = cell(record, 'rpe').trim();
    const exerciseNotesRaw = cell(record, 'exercise_notes').trim();
    const supersetRaw = cell(record, 'superset_id').trim();
    const description = cell(record, 'description').trim();

    const startMs = parseHevyDateTime(startRaw, tzOffset);
    if (startMs == null) {
      quarantined.push({ rowNumber, column: 'start_time', value: startRaw, message: 'unparseable start_time' });
      return;
    }
    if (exerciseTitle === '') {
      quarantined.push({ rowNumber, column: 'exercise_title', value: '', message: 'blank exercise_title' });
      return;
    }
    if (setIndexRaw !== '' && !INT_RE.test(setIndexRaw)) {
      quarantined.push({ rowNumber, column: 'set_index', value: setIndexRaw, message: 'malformed set_index' });
      return;
    }
    if (weightKgRaw !== '' && !DOUBLE_RE.test(weightKgRaw)) {
      quarantined.push({ rowNumber, column: 'weight_kg', value: weightKgRaw, message: 'malformed weight_kg' });
      return;
    }
    if (weightLbsRaw !== '' && !DOUBLE_RE.test(weightLbsRaw)) {
      quarantined.push({ rowNumber, column: 'weight_lbs', value: weightLbsRaw, message: 'malformed weight_lbs' });
      return;
    }
    if (repsRaw !== '' && !INT_RE.test(repsRaw)) {
      quarantined.push({ rowNumber, column: 'reps', value: repsRaw, message: 'malformed reps' });
      return;
    }
    if (durationRaw !== '' && !INT_RE.test(durationRaw)) {
      quarantined.push({ rowNumber, column: 'duration_seconds', value: durationRaw, message: 'malformed duration_seconds' });
      return;
    }

    if (rpeRaw !== '') counts.metadataDropped.rpe += 1;
    if (exerciseNotesRaw !== '') counts.metadataDropped.exerciseNotes += 1;
    if (supersetRaw !== '') counts.metadataDropped.supersetId += 1;

    const setType = setTypeRaw.toLowerCase();
    const weightRaw = declaredUnit === 'kg' ? weightKgRaw : declaredUnit === 'lb' ? weightLbsRaw : '';
    validRows.push({
      rowNumber, title, description, startTimeMs: startMs, startTimeISO: isoUTC(startMs),
      endTimeRaw: cell(record, 'end_time').trim(), exerciseTitle, setIndexRaw, setType,
      weightRaw, repsRaw, distanceKmRaw, distanceMilesRaw, durationRaw,
    });
  });

  counts.quarantinedCount = quarantined.length;
  const nonEmptyDataRows = counts.dataRows - counts.emptyRowsSkipped;
  if (quarantined.length * 2 > nonEmptyDataRows)
    throw notHevyExport("majority of rows unparseable — doesn't look like a Hevy export");

  const sessionOrder = [];
  const sessionsByKey = new Map();
  const newExerciseOrder = [];
  const newExercisesByName = new Map();

  for (const row of validRows) {
    const titleKey = row.title.toLowerCase();
    const sessionKey = `${titleKey}|${row.startTimeISO}`;
    let acc = sessionsByKey.get(sessionKey);
    if (!acc) {
      acc = { importKey: sessionKey, displayTitle: row.title, notes: null, endedAt: null, setPlans: [], seen: new Set() };
      sessionsByKey.set(sessionKey, acc);
      sessionOrder.push(sessionKey);
    }
    if (acc.notes == null && row.description !== '') acc.notes = unescapeHevyNewlines(row.description);
    if (acc.endedAt == null && row.endTimeRaw !== '') {
      const endMs = parseHevyDateTime(row.endTimeRaw, tzOffset);
      if (endMs != null) acc.endedAt = isoUTC(endMs);
    }

    const normEx = normalize(row.exerciseTitle);
    const dedupeKey = `${normEx}\u0001${row.setIndexRaw}`;
    if (acc.seen.has(dedupeKey)) { counts.duplicatesCollapsed += 1; continue; }
    acc.seen.add(dedupeKey);

    let ref;
    const match = matchLibrary(normEx, library);
    if (match) { ref = { existing: match.id }; counts.exercisesMatched += 1; }
    else ref = { new: normEx };

    const reps = row.repsRaw === '' ? null : parseInt(row.repsRaw, 10);
    const duration = row.durationRaw === '' ? null : parseInt(row.durationRaw, 10);
    let actualWeight = row.weightRaw === '' ? null : parseFloat(row.weightRaw);
    if (actualWeight === 0) actualWeight = null;                    // bodyweight rule

    const isDurationSet = (reps == null || reps === 0) && (duration ?? 0) > 0;
    const hasDistance = !(row.distanceKmRaw === '' && row.distanceMilesRaw === '');
    let setReps, setDuration;
    if (isDurationSet) {
      setReps = null; setDuration = duration;
    } else if (reps != null && reps > 0) {
      setReps = reps; setDuration = null;
    } else if (hasDistance) {
      counts.cardioRowsSkipped += 1;
      continue;
    } else {
      quarantined.push({ rowNumber: row.rowNumber, column: 'reps/duration_seconds', value: '', message: 'no reps or duration payload' });
      counts.quarantinedCount += 1;
      continue;
    }

    // BR-009: register a new custom exercise ONLY once a row is actually
    // accepted as a set — cardio-skipped/quarantined rows never create one.
    if (ref.new && !newExercisesByName.has(normEx)) {
      newExerciseOrder.push(normEx);
      newExercisesByName.set(normEx, { displayName: displayForm(row.exerciseTitle), durationMetric: false });
    }
    if (ref.new && isDurationSet) newExercisesByName.get(normEx).durationMetric = true;
    // BR-006: fold count applies to sets actually imported (collapsed duplicates
    // are never imported, so they never fold).
    if (row.setType === 'warmup' || row.setType === 'failure' || row.setType === 'dropset') counts.foldedSetTypes += 1;

    const effectiveUnit = options.unitOverrides?.[normEx] ?? declaredUnit;
    if (actualWeight != null && effectiveUnit && effectiveUnit !== options.targetUnit) {
      actualWeight = effectiveUnit === 'kg' ? actualWeight * LB_PER_KG : actualWeight * KG_PER_LB;
    }

    acc.setPlans.push({
      exerciseRef: ref, sortOrder: acc.setPlans.length,
      actualWeight, actualReps: setReps, actualDuration: setDuration, completedAt: '',
    });
  }

  const sessions = [];
  for (const key of sessionOrder) {
    const acc = sessionsByKey.get(key);
    if (acc.setPlans.length === 0) continue;                        // cardio-only session
    const completedAt = acc.endedAt ?? isoFromKey(key);
    const sets = acc.setPlans.map((p) => ({ ...p, completedAt }));
    const alreadyImported = options.existingImportKeys?.has(key) === true;
    if (alreadyImported) counts.sessionsAlreadyImported += 1;
    else counts.setsImported += sets.length;
    sessions.push({
      importKey: key,
      name: acc.displayTitle === '' ? UNTITLED : acc.displayTitle,
      notes: acc.notes,
      startedAt: isoFromKey(key),
      endedAt: acc.endedAt,
      sets,
      alreadyImported,
    });
  }
  counts.sessionsFound = sessions.length;

  const newExercises = newExerciseOrder.map((norm) => {
    const e = newExercisesByName.get(norm);
    return { name: e.displayName, normalizedName: norm, metric: e.durationMetric ? 'duration' : 'reps' };
  });

  return {
    unit: declaredUnit, now: options.now ?? NOW,
    sessions, newExercises, quarantined, counts, warnings,
  };
}

// ---- PR re-derivation mirror (SC-prs@1.0.0 BR-009, as in VerifyRecords.mjs) ----
const KINDS = ['max_1rm', 'max_volume', 'max_reps', 'max_duration'];
const epley = (w, r) => w * (1 + r / 30);

function prValue(kind, s, metric) {
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

function rederiveExercisePRs(db, exerciseId, metric, now) {
  const history = db.prepare(
    `SELECT id, sessionId, status, setClass, actualWeight, actualReps, actualDuration, completedAt
       FROM completed_set WHERE exerciseId = ? AND deletedAt IS NULL`).all(exerciseId);
  const work = history.filter((s) => s.status === 'completed' && (s.setClass ?? 'work') === 'work');
  const bestValue = {}, bestHolder = {};
  for (const s of work) {
    for (const kind of KINDS) {
      const v = prValue(kind, s, metric);
      if (v == null) continue;
      if (bestValue[kind] == null
        || v > bestValue[kind]
        || (v === bestValue[kind] && earlierWins(s, bestHolder[kind]))) {
        bestValue[kind] = v; bestHolder[kind] = s;
      }
    }
  }
  for (const kind of KINDS) {
    const existing = db.prepare(
      `SELECT id, value, setId FROM personal_record WHERE exerciseId = ? AND kind = ? AND deletedAt IS NULL`)
      .get(exerciseId, kind);
    const t = bestValue[kind];
    if (existing && t != null) {
      const holder = bestHolder[kind];
      if (existing.value !== t || existing.setId !== holder.id) {
        db.prepare(`UPDATE personal_record SET value = ?, setId = ?, sessionId = ?, achievedAt = ?, updatedAt = ? WHERE id = ?`)
          .run(t, holder.id, holder.sessionId, holder.completedAt ?? now, now, existing.id);
      }
    } else if (!existing && t != null) {
      const holder = bestHolder[kind];
      db.prepare(`INSERT INTO personal_record (id, exerciseId, sessionId, setId, kind, value, achievedAt, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(randomUUID(), exerciseId, holder.sessionId, holder.id, kind, t, holder.completedAt ?? now, now, now);
    } else if (existing && t == null) {
      db.prepare(`UPDATE personal_record SET deletedAt = ?, updatedAt = ? WHERE id = ?`).run(now, now, existing.id);
    }
  }
}
const earlierWins = (a, b) => {
  const at = a.completedAt ?? '', bt = b.completedAt ?? '';
  if (at !== bt) return at < bt;
  return a.id < b.id;
};

// ---- DAO apply mirror (HevyImportDAO.apply, BR-015/BR-016) ----
function applyPlan(db, plan) {
  const now = plan.now;
  const summary = { sessionsImported: 0, sessionsSkippedAlreadyImported: 0, setsImported: 0, exercisesCreated: 0 };
  const tx = db.transaction(() => {
    const liveExercises = db.prepare(`SELECT id, name, exerciseType, isCustom FROM exercise WHERE deletedAt IS NULL`).all();
    const idByNormalized = {};
    const metricById = {};
    for (const r of liveExercises) {
      idByNormalized[normalize(r.name)] = r.id;
      metricById[r.id] = r.exerciseType === 'cardio' ? 'duration' : 'reps';
    }
    const idForNew = {};
    for (const ne of plan.newExercises) {
      if (idByNormalized[ne.normalizedName]) { idForNew[ne.normalizedName] = idByNormalized[ne.normalizedName]; continue; }
      const id = randomUUID();
      const exerciseType = ne.metric === 'duration' ? 'cardio' : 'custom';     // INV-IM8
      db.prepare(`INSERT INTO exercise (id, name, exerciseType, isCustom, createdAt, updatedAt) VALUES (?, ?, ?, 1, ?, ?)`)
        .run(id, ne.name, exerciseType, now, now);
      idByNormalized[ne.normalizedName] = id;
      metricById[id] = ne.metric;
      idForNew[ne.normalizedName] = id;
      summary.exercisesCreated += 1;
    }
    const affected = [];
    const affectedSeen = new Set();
    for (const session of plan.sessions) {
      if (session.alreadyImported) { summary.sessionsSkippedAlreadyImported += 1; continue; }
      const sessionId = randomUUID();
      const info = db.prepare(`
        INSERT OR IGNORE INTO workout_session
          (id, name, notes, startedAt, endedAt, importSource, importKey, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, 'hevy', ?, ?, ?)`)
        .run(sessionId, session.name, session.notes, session.startedAt, session.endedAt, session.importKey, now, now);
      if (info.changes === 0) { summary.sessionsSkippedAlreadyImported += 1; continue; }   // UNIQUE backstop
      summary.sessionsImported += 1;
      for (const set of session.sets) {
        const exerciseId = set.exerciseRef.existing ?? idForNew[set.exerciseRef.new];
        if (!exerciseId) throw new Error(`unresolvedExercise: ${set.exerciseRef.new}`);
        db.prepare(`
          INSERT INTO completed_set
            (id, sessionId, exerciseId, sortOrder, plannedWeight, plannedReps, plannedDuration,
             actualWeight, actualReps, actualDuration, status, completedAt, createdAt, updatedAt)
          VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?, 'completed', ?, ?, ?)`)
          .run(randomUUID(), sessionId, exerciseId, set.sortOrder,
            set.actualWeight, set.actualReps, set.actualDuration, set.completedAt, now, now);
        summary.setsImported += 1;
        if (!affectedSeen.has(exerciseId)) { affectedSeen.add(exerciseId); affected.push(exerciseId); }
      }
    }
    for (const exerciseId of affected) rederiveExercisePRs(db, exerciseId, metricById[exerciseId] ?? 'reps', now);
  });
  tx();
  return summary;
}

// ---- DB plumbing ----
function newDb() {
  const db = new Database(':memory:');
  for (const m of MIGRATIONS) db.exec(readFileSync(m, 'utf8'));
  return db;
}

function seedLibrary(db) {
  const seed = JSON.parse(readFileSync(SEED, 'utf8'));
  const stmt = db.prepare(`INSERT OR IGNORE INTO exercise (id, name, exerciseType, equipmentSlug, isCustom, createdAt, updatedAt) VALUES (?, ?, ?, ?, 0, ?, ?)`);
  for (const ex of seed.exercises) {
    // INV-IM8 precedent: duration metric ⇔ exerciseType='cardio' (SC-prs metric resolution).
    stmt.run(ex.id, ex.name, ex.defaultMetric === 'duration' ? 'cardio' : 'strength', ex.equipment ?? null, NOW, NOW);
  }
  return seed.exercises.length;
}

function libraryRows(db) {
  return db.prepare(`SELECT id, name, equipmentSlug, isCustom FROM exercise WHERE deletedAt IS NULL`)
    .all()
    .map((r) => ({ id: r.id, name: r.name, nameNormalized: normalize(r.name), equipmentSlug: r.equipmentSlug, isCustom: r.isCustom === 1 }));
}

const probeImportKeys = (db) => new Set(
  db.prepare(`SELECT importKey FROM workout_session WHERE deletedAt IS NULL AND importKey IS NOT NULL`).all().map((r) => r.importKey));

function dbSnapshot(db) {
  const dump = (table) => db.prepare(`SELECT * FROM ${table} ORDER BY id`).all();
  return JSON.stringify({
    workout_session: dump('workout_session'),
    completed_set: dump('completed_set'),
    exercise: dump('exercise'),
    personal_record: dump('personal_record'),
  });
}

// ---- 100-session generator (fixture 01; deterministic, no RNG) ----
function generateHundredSessionsCsv() {
  const titles = ['Push Day', 'Pull Day', 'Leg Day', 'Core Day', 'Full Body'];
  const exercises = ['Barbell Bench Press', 'Squat (Barbell)', 'Mystery Gizmo Lift'];
  const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const lines = ['title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps'];
  for (let i = 0; i < 100; i++) {
    const d = new Date(Date.UTC(2025, 0, 1 + i));
    const dateStr = `${pad2(d.getUTCDate())} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
    const title = titles[i % 5];
    for (const ex of exercises) {
      for (let s = 0; s < 3; s++) {
        const weight = 20 + ((i + s * 7) % 41) * 2.5;
        const reps = 5 + ((i + s) % 8);
        lines.push(`"${title}","${dateStr}, 08:00","${dateStr}, 08:55",${ex},${s},normal,${weight},${reps}`);
      }
    }
  }
  return lines.join('\n') + '\n';
}

// ---- schema sanity: 0003 import columns + UNIQUE partial index ----
(function schemaShape() {
  const db = newDb();
  const cols = db.prepare(`PRAGMA table_info(workout_session)`).all().map((c) => c.name);
  for (const c of ['name', 'notes', 'importSource', 'importKey', 'routineId']) {
    if (!cols.includes(c)) { fail(`schema.workout_session.${c} missing`); return; }
  }
  db.prepare(`INSERT INTO workout_session (id, startedAt, importSource, importKey, createdAt, updatedAt) VALUES ('s-1','2025-01-01T00:00:00Z','hevy','k|2025-01-01T00:00:00Z','t','t')`).run();
  let ignored = false;
  try {
    const info = db.prepare(`INSERT OR IGNORE INTO workout_session (id, startedAt, importSource, importKey, createdAt, updatedAt) VALUES ('s-2','2025-01-01T00:00:00Z','hevy','k|2025-01-01T00:00:00Z','t','t')`).run();
    ignored = info.changes === 0;
  } catch { ignored = false; }
  if (!ignored) { fail('schema.importKey-unique: duplicate importKey must be ignored'); return; }
  // NULL importKeys (hand-entered sessions) never collide — partial index scope.
  db.prepare(`INSERT INTO workout_session (id, startedAt, createdAt, updatedAt) VALUES ('s-3','2025-01-02T00:00:00Z','t','t')`).run();
  db.prepare(`INSERT INTO workout_session (id, startedAt, createdAt, updatedAt) VALUES ('s-4','2025-01-03T00:00:00Z','t','t')`).run();
  pass('schema.import-columns.canonical');
})();

// ---- assertion walkers ----
function assertCounts(actual, wanted, id) {
  for (const [k, v] of Object.entries(wanted)) {
    if (k === 'metadataDropped') {
      for (const [mk, mv] of Object.entries(v)) eq(actual.metadataDropped[mk], mv, `${id}.counts.metadataDropped.${mk}`);
    } else {
      eq(actual[k], v, `${id}.counts.${k}`);
    }
  }
}

function assertPlanSessions(actualSessions, wanted, id) {
  if (actualSessions.length !== wanted.length) {
    fail(`${id}.sessions.length: expected ${wanted.length}, got ${actualSessions.length}`);
    return;
  }
  wanted.forEach((w, i) => {
    const a = actualSessions[i];
    for (const [k, v] of Object.entries(w)) {
      if (k === 'setCount') eq(a.sets.length, v, `${id}.sessions[${i}].setCount`);
      else eq(a[k], v, `${id}.sessions[${i}].${k}`);
    }
  });
}

function assertDb(db, want, id) {
  if (want.sessions != null)
    eq(db.prepare(`SELECT COUNT(*) c FROM workout_session WHERE deletedAt IS NULL`).get().c, want.sessions, `${id}.db.sessions`);
  if (want.sets != null)
    eq(db.prepare(`SELECT COUNT(*) c FROM completed_set WHERE deletedAt IS NULL`).get().c, want.sets, `${id}.db.sets`);
  if (want.customExercises != null)
    eq(db.prepare(`SELECT COUNT(*) c FROM exercise WHERE isCustom = 1 AND deletedAt IS NULL`).get().c, want.customExercises, `${id}.db.customExercises`);

  if (want.allSessionsImported) {
    const bad = db.prepare(`SELECT COUNT(*) c FROM workout_session WHERE deletedAt IS NULL AND (importSource != 'hevy' OR importKey IS NULL OR name IS NULL)`).get().c;
    eq(bad, 0, `${id}.db.allSessionsImported`);
  }
  if (want.allSetsImportedShape) {
    const bad = db.prepare(`
      SELECT COUNT(*) c FROM completed_set WHERE deletedAt IS NULL AND (
        status != 'completed' OR plannedWeight IS NOT NULL OR plannedReps IS NOT NULL
        OR plannedDuration IS NOT NULL OR setClass IS NOT NULL OR completedAt IS NULL)`).get().c;
    eq(bad, 0, `${id}.db.allSetsImportedShape`);
    // sortOrder contiguity per session (SC-foundation BR-005).
    const sessions = db.prepare(`SELECT DISTINCT sessionId FROM completed_set WHERE deletedAt IS NULL`).all();
    let contiguous = true;
    for (const s of sessions) {
      const orders = db.prepare(`SELECT sortOrder FROM completed_set WHERE sessionId = ? AND deletedAt IS NULL ORDER BY sortOrder`).all(s.sessionId).map((r) => r.sortOrder);
      if (orders.some((o, i) => o !== i)) { contiguous = false; break; }
    }
    eq(contiguous, true, `${id}.db.sortOrderContiguous`);
  }

  for (const [i, w] of (want.sessionRows ?? []).entries()) {
    const row = db.prepare(`SELECT * FROM workout_session WHERE importKey = ? AND deletedAt IS NULL`).get(w.importKey);
    if (!row) { fail(`${id}.db.sessionRows[${i}]: no session for importKey ${w.importKey}`); continue; }
    if ('name' in w) eq(row.name, w.name, `${id}.db.sessionRows[${i}].name`);
    if ('notes' in w) eq(row.notes, w.notes, `${id}.db.sessionRows[${i}].notes`);
    if ('importSource' in w) eq(row.importSource, w.importSource, `${id}.db.sessionRows[${i}].importSource`);
    if ('startedAt' in w) eq(row.startedAt, w.startedAt, `${id}.db.sessionRows[${i}].startedAt`);
    if ('endedAt' in w) eq(row.endedAt, w.endedAt, `${id}.db.sessionRows[${i}].endedAt`);
    if (w.routineIdNull) eq(row.routineId, null, `${id}.db.sessionRows[${i}].routineIdNull`);
  }

  for (const [i, w] of (want.setRows ?? []).entries()) {
    const row = db.prepare(`
      SELECT cs.*, e.name AS exerciseName FROM completed_set cs
      JOIN workout_session ws ON ws.id = cs.sessionId
      JOIN exercise e ON e.id = cs.exerciseId
      WHERE ws.importKey = ? AND cs.sortOrder = ? AND cs.deletedAt IS NULL`)
      .get(w.sessionImportKey, w.sortOrder);
    if (!row) { fail(`${id}.db.setRows[${i}]: no set for ${w.sessionImportKey} sortOrder ${w.sortOrder}`); continue; }
    if ('exerciseName' in w) eq(row.exerciseName, w.exerciseName, `${id}.db.setRows[${i}].exerciseName`);
    if ('actualWeight' in w) {
      if (w.actualWeight == null) eq(row.actualWeight, null, `${id}.db.setRows[${i}].actualWeight-null`);
      else approx(row.actualWeight, w.actualWeight, `${id}.db.setRows[${i}].actualWeight`);
    }
    if ('actualReps' in w) eq(row.actualReps, w.actualReps, `${id}.db.setRows[${i}].actualReps`);
    if ('actualDuration' in w) eq(row.actualDuration, w.actualDuration, `${id}.db.setRows[${i}].actualDuration`);
    if ('status' in w) eq(row.status, w.status, `${id}.db.setRows[${i}].status`);
    if ('completedAt' in w) eq(row.completedAt, w.completedAt, `${id}.db.setRows[${i}].completedAt`);
    if (w.plannedNull) {
      const allNull = row.plannedWeight == null && row.plannedReps == null && row.plannedDuration == null;
      eq(allNull, true, `${id}.db.setRows[${i}].plannedNull`);
    }
  }

  for (const [i, w] of (want.exerciseRows ?? []).entries()) {
    const row = db.prepare(`SELECT * FROM exercise WHERE name = ? AND deletedAt IS NULL`).get(w.name);
    if (!row) { fail(`${id}.db.exerciseRows[${i}]: no exercise named ${w.name}`); continue; }
    if ('exerciseType' in w) eq(row.exerciseType, w.exerciseType, `${id}.db.exerciseRows[${i}].exerciseType`);
    if ('isCustom' in w) eq(row.isCustom, w.isCustom, `${id}.db.exerciseRows[${i}].isCustom`);
  }

  if (want.prKindsByExercise) {
    for (const [exerciseName, kinds] of Object.entries(want.prKindsByExercise)) {
      const ex = db.prepare(`SELECT id FROM exercise WHERE name = ? AND deletedAt IS NULL`).get(exerciseName);
      if (!ex) { fail(`${id}.db.prKinds: no exercise ${exerciseName}`); continue; }
      const live = db.prepare(`SELECT kind FROM personal_record WHERE exerciseId = ? AND deletedAt IS NULL ORDER BY kind`).all(ex.id).map((r) => r.kind);
      eq(JSON.stringify([...live].sort()), JSON.stringify([...kinds].sort()), `${id}.db.prKinds.${exerciseName}`);
    }
  }

  for (const [i, w] of (want.prRows ?? []).entries()) {
    const ex = db.prepare(`SELECT id FROM exercise WHERE name = ? AND deletedAt IS NULL`).get(w.exerciseName);
    if (!ex) { fail(`${id}.db.prRows[${i}]: no exercise ${w.exerciseName}`); continue; }
    const rows = db.prepare(`SELECT * FROM personal_record WHERE exerciseId = ? AND kind = ? AND deletedAt IS NULL`).all(ex.id, w.kind);
    if (rows.length !== 1) { fail(`${id}.db.prRows[${i}]: expected exactly 1 live row for ${w.exerciseName}/${w.kind}, got ${rows.length}`); continue; }
    approx(rows[0].value, w.value, `${id}.db.prRows[${i}].value`);
    if (rows[0].setId == null) fail(`${id}.db.prRows[${i}].setId: must point at the holding set`);
    else pass(`${id}.db.prRows[${i}].setId`);
    if (rows[0].sessionId == null || rows[0].sessionId === '') fail(`${id}.db.prRows[${i}].sessionId: must point at the session`);
    else pass(`${id}.db.prRows[${i}].sessionId`);
  }

  if (want.prLiveTotal != null)
    eq(db.prepare(`SELECT COUNT(*) c FROM personal_record WHERE deletedAt IS NULL`).get().c, want.prLiveTotal, `${id}.db.prLiveTotal`);
}

// ---- fixture runner ----
const files = readdirSync(FIXT).filter((f) => f.endsWith('.json')).sort();
for (const fname of files) {
  const fx = JSON.parse(readFileSync(join(FIXT, fname), 'utf8'));
  console.log(`\n-- ${fname}: ${fx.label ?? ''}`);

  for (const v of fx.vectors ?? []) {
    const id = `${fname}.${v.id}`;
    const db = newDb();
    seedLibrary(db);
    for (const c of fx.seed?.customExercises ?? []) {
      db.prepare(`INSERT INTO exercise (id, name, exerciseType, isCustom, createdAt, updatedAt) VALUES (?, ?, ?, 1, ?, ?)`)
        .run(c.id, c.name, c.exerciseType ?? 'custom', NOW, NOW);
    }

    const csvText = v.generate === 'hundredSessions'
      ? generateHundredSessionsCsv()
      : v.csv != null ? v.csv : readFileSync(join(FIXT, v.csvFile), 'utf8');

    const options = {
      targetUnit: v.options?.targetUnit ?? 'kg',
      timezoneOffsetMinutes: v.options?.timezoneOffsetMinutes ?? 0,
      now: v.options?.now ?? NOW,
      unitOverrides: v.options?.unitOverrides ?? {},
      existingImportKeys: probeImportKeys(db),
    };

    let plan = null, buildError = null;
    try { plan = buildPlan(csvText, libraryRows(db), options); }
    catch (e) { buildError = e; }

    if (v.expectAbort) {
      if (!buildError) fail(`${id}.abort: expected ${v.expectAbort}, plan built`);
      else eq(buildError.code, v.expectAbort, `${id}.abort`);
      if (v.db) assertDb(db, v.db, id);          // nothing written on abort (INV-IM2)
      continue;
    }
    if (buildError) { fail(`${id}.build: unexpected error ${buildError.code}: ${buildError.message}`); continue; }

    const ex = v.expect ?? {};
    if ('unit' in ex) eq(plan.unit, ex.unit, `${id}.unit`);
    if ('warnings' in ex) eq(JSON.stringify(plan.warnings), JSON.stringify(ex.warnings), `${id}.warnings`);
    if ('counts' in ex) assertCounts(plan.counts, ex.counts, id);
    if ('quarantined' in ex) {
      eq(plan.quarantined.length, ex.quarantined.length, `${id}.quarantined.length`);
      ex.quarantined.forEach((w, i) => {
        const a = plan.quarantined[i];
        if (!a) { fail(`${id}.quarantined[${i}] missing`); return; }
        if ('rowNumber' in w) eq(a.rowNumber, w.rowNumber, `${id}.quarantined[${i}].rowNumber`);
        if ('column' in w) eq(a.column, w.column, `${id}.quarantined[${i}].column`);
        if ('value' in w) eq(a.value, w.value, `${id}.quarantined[${i}].value`);
        if ('messageContains' in w) eq(a.message.includes(w.messageContains), true, `${id}.quarantined[${i}].message`);
      });
    }
    if ('newExercises' in ex) {
      eq(JSON.stringify(plan.newExercises), JSON.stringify(ex.newExercises), `${id}.newExercises`);
    }
    if ('sessions' in ex) assertPlanSessions(plan.sessions, ex.sessions, id);
    if ('sessionsHead' in ex) assertPlanSessions(plan.sessions.slice(0, ex.sessionsHead.length), ex.sessionsHead, `${id}.head`);

    // ---- apply (BR-015) ----
    let summary = null, applyError = null;
    try { summary = applyPlan(db, plan); }
    catch (e) { applyError = e; }
    if (applyError) { fail(`${id}.apply: ${applyError.message}`); continue; }
    if ('summary' in ex) {
      for (const [k, val] of Object.entries(ex.summary)) eq(summary[k], val, `${id}.summary.${k}`);
    }
    if ('db' in ex) assertDb(db, ex.db, id);

    // ---- re-import (BR-013 idempotency) ----
    if (v.reimport) {
      const beforeReimport = dbSnapshot(db);
      const options2 = { ...options, existingImportKeys: probeImportKeys(db) };
      const plan2 = buildPlan(csvText, libraryRows(db), options2);
      const rex = v.reimport.expect ?? {};
      if ('counts' in rex) assertCounts(plan2.counts, rex.counts, `${id}.reimport`);
      const summary2 = applyPlan(db, plan2);
      if ('summary' in rex) {
        for (const [k, val] of Object.entries(rex.summary)) eq(summary2[k], val, `${id}.reimport.summary.${k}`);
      }
      if (v.reimport.dbUnchanged) {
        eq(dbSnapshot(db), beforeReimport, `${id}.reimport.dbUnchanged`);
      }
    }
  }
}

console.log('');
if (failures === 0) { console.log(`ALL IMPORT FIXTURES PASS (${passes} checks)`); process.exit(0); }
console.error(`${failures} check(s) failed`);
process.exit(1);
