// Seam-1 verifier for SC-progression@1.0.0 (ticket #24).
// Mirrors ProgressionEngine.swift's math in JS so vectors run on Windows; the same
// vectors are mirrored as XCTest expectations in ProgressionEngineTests.swift.
//
// Usage: node Tests/MooreProgressionTests/VerifyProgression.mjs

import Database from 'better-sqlite3';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const worktreeRoot = join(here, '..', '..');
const FIXT = join(here, 'Fixtures');

// Migrations: foundation (0001..0003) + routines (0005, 0006) + progression (0007).
// 0004 is skipped per docs/MIGRATION-INTEGRATION-NOTE.md (agents wait for rewrite).
const MIGRATIONS = [
  'Sources/MooreFoundation/Migrations/0001_core.sql',
  'Sources/MooreFoundation/Migrations/0002_warmup_progression.sql',
  'Sources/MooreFoundation/Migrations/0003_import_columns.sql',
  'Sources/MooreRoutines/Migrations/0005_routines_folders.sql',
  'Sources/MooreRoutines/Migrations/0006_routines_session_link.sql',
  'Sources/MooreProgression/Migrations/0007_progression_full.sql',
].map((p) => join(worktreeRoot, ...p.split('/')));

let failures = 0, passes = 0;
const fail = (m) => { console.error(`FAIL: ${m}`); failures += 1; };
const pass = (m) => { console.log(`PASS: ${m}`); passes += 1; };
const eq = (a, b, label) => (a === b ? pass(label) : fail(`${label}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`));

function newDb() {
  const db = new Database(':memory:');
  for (const m of MIGRATIONS) db.exec(readFileSync(m, 'utf8'));
  return db;
}

// Sanity: progression_scheme post-0007 shape matches contract §2.
(function schemaShape() {
  const db = newDb();
  const cols = db.prepare(`PRAGMA table_info(progression_scheme)`).all().map((c) => c.name);
  for (const c of ['nextBannerAt', 'deloadPending', 'stalledWeight', 'stalledReps', 'stalledDurationSec', 'baselineDurationSec'])
    if (!cols.includes(c)) { fail(`schema.missing ${c} on progression_scheme`); return; }
  pass('schema.progression-scheme.canonical');
})();

// ---- JS mirror of ProgressionEngine (Swift file is the source of truth; tests
// are mirrored 1:1 from the same Acceptance Criteria vectors) ----
const incFor = (cat) => {
  if (!cat) return 2.5;
  const c = String(cat).toLowerCase();
  return ['legs', 'quads', 'hamstrings', 'glutes', 'calves'].some((k) => c.includes(k)) ? 5.0 : 2.5;
};
const round125 = (x) => Math.max(0, Math.round(x / 1.25 + (x % 1.25 >= 0.625 ? 0.5 : 0)) * 1.25);
const round25 = (x) => Math.max(0, Math.round(x / 2.5 + (x % 2.5 >= 1.25 ? 0.5 : 0)) * 2.5);

function clean(sets, metric) {
  const performed = sets.filter((s) => s.status !== 'dropped');
  if (!performed.length) return false;
  if (performed.some((s) => s.status === 'failed')) return false;
  return performed.every((s) =>
    metric === 'reps'
      ? (s.actualReps ?? 0) >= (s.plannedReps ?? 0)
      : (s.actualDuration ?? 0) >= (s.plannedDuration ?? 0)
  );
}
const failedMax = (sets, metric) => {
  const fails = sets.filter((s) => s.status === 'failed');
  if (!fails.length) return null;
  return Math.max(...fails.map((s) => (metric === 'reps' ? s.actualReps : s.actualDuration) ?? 0));
};

function suggest(rec, reference, metric, category, blueprint) {
  if (!reference || reference.length === 0) return { ...blueprint, touched: ['blueprint-verbatim'], rec };
  let r = { ...rec };
  if (r.deloadPending && r.stalledWeight != null) {
    r.deloadPending = 0; r.lastDeloadSessionId = null; r.stallCount = 0;
    return { weight: round25(r.stalledWeight * 0.9), reps: r.stalledReps ?? null, durationSec: r.stalledDurationSec ?? null, touched: ['deload-applied'], rec: r };
  }
  if (r.lastDeloadSessionId && reference.length && reference[0].sessionId === r.lastDeloadSessionId) {
    return metric === 'reps'
      ? { weight: r.stalledWeight, reps: r.stalledReps, durationSec: null, touched: ['deload-reentry'], rec: r }
      : { weight: r.stalledWeight, reps: null, durationSec: r.stalledDurationSec, touched: ['deload-reentry'], rec: r };
  }
  const performed = reference.filter((s) => s.status !== 'dropped');
  if (!performed.length) return { ...blueprint, touched: ['blueprint-verbatim'], rec: r };
  const last = [...performed].sort((a, b) => a.setOrdinal - b.setOrdinal).pop();
  const W = last.actualWeight;
  const P = metric === 'reps' ? last.plannedReps : last.plannedDuration;
  const C = clean(performed, metric);
  const F = failedMax(performed, metric);
  if (!C) {
    const target = F != null && P != null ? Math.min(P, F) : F ?? P;
    return metric === 'reps'
      ? { weight: W, reps: target, durationSec: null, touched: ['hold-weight-from-fail'], rec: r }
      : { weight: W, reps: null, durationSec: target, touched: ['hold-weight-from-fail'], rec: r };
  }
  const inc = incFor(category);
  switch (rec.scheme) {
    case 'none':
      return { weight: W, reps: last.actualReps, durationSec: last.actualDuration, touched: ['none-verbatim'], rec: r };
    case 'linear':
      if (W == null) return { weight: null, reps: last.actualReps, durationSec: last.actualDuration, touched: ['linear-degenerate-none'], rec: r };
      return { weight: round125(W + inc), reps: last.plannedReps, durationSec: last.plannedDuration, touched: ['linear'], rec: r };
    case 'double': {
      const reps = last.actualReps ?? (last.plannedReps ?? 8);
      if (reps >= 12 && W != null)
        return { weight: round125(W + inc), reps: 8, touched: ['double-ceiling'], rec: r };
      return { weight: W, reps: Math.min(reps + 1, 12), touched: ['double-reps'], rec: r };
    }
    case 'hold-duration': {
      const baseline = rec.baselineDurationSec ?? last.plannedDuration ?? 60;
      const cap = baseline + 60;
      return { weight: null, durationSec: Math.min((last.actualDuration ?? baseline) + 5, cap), touched: ['hold-duration'], rec: r };
    }
  }
}

// Stall lifecycle mirror.
function stallStep(rec, currentSets, previousWeight, metric) {
  const performedNow = currentSets.filter((s) => s.status !== 'dropped');
  if (!performedNow.length) return { banner: false, copy: null, rec };
  let r = { ...rec };
  const currentW = performedNow[performedNow.length - 1].actualWeight;
  if (previousWeight != null && currentW != null && previousWeight !== currentW) {
    r.stallCount = 0;
    return { banner: false, copy: null, rec: r };
  }
  if (clean(performedNow, metric)) { r.stallCount = 0; return { banner: false, copy: null, rec: r }; }
  const F = failedMax(performedNow, metric);
  const P = metric === 'reps' ? performedNow[0].plannedReps : performedNow[0].plannedDuration;
  if (F != null && P != null && F < P) r.stallCount += 1;
  if (!r.stallMuted && r.stallCount === r.nextBannerAt) {
    return { banner: true, copy: `Looks stalled on EX — ${r.stallCount} sessions short of target.`, rec: r };
  }
  return { banner: false, copy: null, rec: r };
}
const applyStall = (action, rec, w, reps, dur) => {
  const r = { ...rec };
  if (action === 'deload') { r.deloadPending = 1; r.stalledWeight = w; r.stalledReps = reps; r.stalledDurationSec = dur; }
  if (action === 'hold') { r.nextBannerAt = r.stallCount + 2; r.deloadPending = 0; }
  if (action === 'ignore') { r.stallMuted = 1; r.deloadPending = 0; }
  return r;
};

// ---- Run fixture vectors ----
const files = readdirSync(FIXT).filter((f) => f.endsWith('.json')).sort();
for (const fname of files) {
  const fx = JSON.parse(readFileSync(join(FIXT, fname), 'utf8'));
  console.log(`\n-- ${fname}: ${fx.label || ''}`);
  for (const v of fx.vectors || []) {
    const id = `${fname}.${v.id}`;
    const out = suggest(v.rec, v.reference, v.metric || 'reps', v.category ?? null, v.blueprint || {});
    if (v.expect) {
      if ('weight' in v.expect) eq(out.weight, v.expect.weight, `${id}.weight`);
      if ('reps' in v.expect) eq(out.reps, v.expect.reps, `${id}.reps`);
      if ('durationSec' in v.expect) eq(out.durationSec, v.expect.durationSec, `${id}.durationSec`);
      if (v.expect.touched) eq(JSON.stringify(out.touched), JSON.stringify(v.expect.touched), `${id}.touched`);
    }
    // Stall lifecycle tests
    if (v.stall) {
      const r = stallStep(v.rec, v.currentSets || [], v.previousWeight ?? null, v.metric || 'reps');
      if ('banner' in v.stall) eq(r.banner, v.stall.banner, `${id}.stall.banner`);
      if ('copyMatch' in v.stall) {
        const m = new RegExp(v.stall.copyMatch).test(r.copy || '');
        m ? pass(`${id}.stall.copyMatch`) : fail(`${id}.stall.copyMatch: no match on ${JSON.stringify(r.copy)}`);
      }
      if (v.stall.rec) for (const k of Object.keys(v.stall.rec)) eq(r.rec[k], v.stall.rec[k], `${id}.stall.rec.${k}`);
    }
    if (v.stallAction) {
      const r = applyStall(v.stallAction, v.rec, v.stallActionArgs?.weight ?? null, v.stallActionArgs?.reps ?? null, v.stallActionArgs?.durationSec ?? null);
      if (v.stallExpect) for (const k of Object.keys(v.stallExpect)) eq(r[k], v.stallExpect[k], `${id}.stallAction.${k}`);
    }
  }
}

if (failures === 0) { console.log(`\nALL PROGRESSION FIXTURES PASS (${passes} checks)`); process.exit(0); }
console.error(`\n${failures} check(s) failed`); process.exit(1);
