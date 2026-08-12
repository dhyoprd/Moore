// Seam-1 (logic) verifier for SC-cues@1.0.0 (ticket #29). The mirror below is
// a verbatim port of Sources/MooreCues/CueEngine.swift + Cue.swift; fixtures
// encode contract §7 vectors:
//   01-taxonomy-fire-once.json            BR-001/BR-002/BR-003  eight cues, exact channel descriptors; unknown id suppresses
//   02-dedupe-collapse.json               BR-012  same cue <500ms collapses; window advances on fired only
//   03-dedupe-boundary.json               BR-012  >=500ms fires; window keys by cue name
//   04-rest-end-suppressed-post-morph.json BR-006  morph latches rest-end; set log unlatches; drop never unlatches
//   05-rest-end-backgrounded.json         BR-005/INV-C6  only rest-end delivers, as localNotification
//   06-silenced-degradation.json          BR-004  silenced kills audio only; haptic+visual fire
//   07-first-touch-pr-suppression.json    BR-007  no beaten kinds ⇒ firstTouch; set tick still fires
//   08-precedence-one-cue-per-set.json    BR-008  headline max_1rm>max_volume>max_reps>max_duration; tick subsumed
//   09-drop-no-haptic.json                BR-009  drop is visual-only; undo fires nothing; next set unaffected
//   10-confirm-blocking.json              BR-010/INV-C5  the only blocking cue; pendingConfirmation gate
//   11-one-tap-accept-never-blocks.json   BR-011  accept path produces zero blocking dispatches
//   12-ring-buffer-sequence.json          BR-013/INV-C1  fired+suppressed+deduped recorded; 64-entry FIFO wrap
//
// Usage: node Tests/MooreCuesTests/VerifyCues.mjs

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const worktreeRoot = join(here, '..', '..');
const fixturesDir = join(here, 'Fixtures');
const cueSwiftPath = join(worktreeRoot, 'Sources', 'MooreCues', 'Cue.swift');

let failures = 0;
let passes = 0;
const fail = (m) => { console.error(`FAIL: ${m}`); failures += 1; };
const pass = (m) => { passes += 1; console.log(`PASS: ${m}`); };

// ---------------------------------------------------------------------------
// Engine mirror — port of Sources/MooreCues/{Cue.swift, CueEngine.swift}.
// Verbatim logic; if this mirror and the Swift drift, the frozen contract
// SC-cues@1.0.0 is the arbiter (and Swift hosts re-check via CueEngine).
// ---------------------------------------------------------------------------

// §3(a) cue→channel mapping table (#10 taxonomy, verbatim) — mirrors
// CueName.channels in Cue.swift. Source-parity check below asserts the Swift
// file carries the same cue IDs and visual element IDs.
const CHANNELS = {
  'cue.rest.end':          { haptic: 'alert',      audio: true,  visual: 'rest.over',      firesSilenced: true, firesBackgroundedOrLocked: true,  blocking: false },
  'cue.set.completed':     { haptic: 'success',    audio: false, visual: 'set.checkFill',  firesSilenced: true, firesBackgroundedOrLocked: false, blocking: false },
  'cue.set.failed':        { haptic: 'nudge',      audio: false, visual: 'set.failDelta',  firesSilenced: true, firesBackgroundedOrLocked: false, blocking: false },
  'cue.set.dropped':       { haptic: null,         audio: false, visual: 'set.dropUndo',   firesSilenced: true, firesBackgroundedOrLocked: false, blocking: false },
  'cue.pr.achieved':       { haptic: 'celebration', audio: false, visual: 'pr.toast',       firesSilenced: true, firesBackgroundedOrLocked: false, blocking: false },
  'cue.pr.summary':        { haptic: null,         audio: false, visual: 'pr.cards',       firesSilenced: true, firesBackgroundedOrLocked: false, blocking: false },
  'cue.finish.morph':      { haptic: null,         audio: false, visual: 'finish.morph',   firesSilenced: true, firesBackgroundedOrLocked: false, blocking: false },
  'cue.confirm.destructive': { haptic: null,       audio: false, visual: 'confirm.modal',  firesSilenced: true, firesBackgroundedOrLocked: false, blocking: true },
};

// BR-008 headline rule (SC-prs BR-005 order): PRKindPrecedence.order mirror.
const PR_PRECEDENCE = ['max_1rm', 'max_volume', 'max_reps', 'max_duration'];

const DEDUPE_WINDOW_SEC = 0.5;   // CueState.dedupeWindowSec (BR-012)
const RING_CAPACITY = 64;        // CueState.ringCapacity (INV-C1)

const REASON = {
  backgrounded: 'backgrounded',
  morphedToFinish: 'morphedToFinish',
  firstTouch: 'firstTouch',
  prSubsumes: 'prSubsumes',
  dedupe500ms: 'dedupe500ms',
  unknownCue: 'unknownCue',
};

function headlineOf(beatenKinds) {
  let best = null;
  let bestRank = Infinity;
  for (const kind of beatenKinds ?? []) {
    const rank = PR_PRECEDENCE.indexOf(kind);
    if (rank === -1) continue;           // unknown kinds ignored (BR-007)
    if (rank < bestRank) { bestRank = rank; best = kind; }
  }
  return best;
}

class CueStateMirror {
  constructor(context = { appState: 'foreground', silenced: false }) {
    this.context = { ...context };
    this.lastFiredAt = new Map();
    this.prFiredSetIds = new Set();
    this.overlayMorphedToFinish = false;
    this.pendingConfirmation = false;
    this.log = [];
    // Harness bookkeeping (not contract surface): monotonic count of every
    // appended entry, so wrap-around is observable despite FIFO eviction.
    this.totalEntries = 0;
  }
  record(entry) {
    this.log.push(entry);
    this.totalEntries += 1;
    while (this.log.length > RING_CAPACITY) this.log.shift();  // FIFO eviction
  }
  resolveConfirmation() { this.pendingConfirmation = false; }
}

/// One evaluation, BR-014 gate order. Returns zero or one dispatch.
function evaluate(event, state) {
  const channels = CHANNELS[event.cue];

  // INV-C7: unknown/forward-compat cue id ⇒ suppressed, never a crash.
  if (!channels) {
    state.record({ cue: event.cue, at: event.at, outcome: 'suppressed', reason: REASON.unknownCue });
    return [];
  }
  const context = state.context;

  // Gate 1 — BR-005 (INV-C6): only rest-end reaches backgrounded/locked.
  if (context.appState === 'backgroundedOrLocked' && event.cue !== 'cue.rest.end') {
    state.record({ cue: event.cue, at: event.at, outcome: 'suppressed', reason: REASON.backgrounded });
    return [];
  }

  // Gate 2 — BR-006: morphed overlay consumes rest-end (the morph IS the cue).
  if (event.cue === 'cue.rest.end' && state.overlayMorphedToFinish) {
    state.record({ cue: event.cue, at: event.at, outcome: 'suppressed', reason: REASON.morphedToFinish });
    return [];
  }

  // Gate 3 — BR-007: first-touch PR suppression (no beaten kinds to headline).
  let headlineKind = null;
  if (event.cue === 'cue.pr.achieved') {
    headlineKind = headlineOf(event.beatenKinds ?? []);
    if (headlineKind === null) {
      state.record({ cue: event.cue, at: event.at, outcome: 'suppressed', reason: REASON.firstTouch });
      return [];
    }
  }

  // Gate 4 — BR-008 (INV-C4): celebration subsumes the completion tick.
  if (event.cue === 'cue.set.completed' && event.setId != null && state.prFiredSetIds.has(event.setId)) {
    state.record({ cue: event.cue, at: event.at, outcome: 'suppressed', reason: REASON.prSubsumes });
    return [];
  }

  // Gate 5 — BR-012: strictly <500ms since last FIRED dispatch collapses.
  const last = state.lastFiredAt.get(event.cue);
  if (last !== undefined && (event.at - last) < DEDUPE_WINDOW_SEC) {
    state.record({ cue: event.cue, at: event.at, outcome: 'deduped', reason: REASON.dedupe500ms });
    return [];
  }

  // Dispatch — BR-002/BR-004 channels, BR-005 delivery.
  const audio = channels.audio && !context.silenced;
  const delivery = (event.cue === 'cue.rest.end' && context.appState === 'backgroundedOrLocked')
    ? 'localNotification'
    : 'inProcess';
  const dispatch = {
    cue: event.cue,
    haptic: channels.haptic ?? null,
    audio,
    visual: channels.visual,
    blocking: channels.blocking,
    delivery,
    headlineKind,
  };

  // Commit side effects (§2a). Fired outcomes only.
  state.record({ cue: event.cue, at: event.at, outcome: 'fired', reason: null });
  state.lastFiredAt.set(event.cue, event.at);
  switch (event.cue) {
    case 'cue.finish.morph':
      state.overlayMorphedToFinish = true;
      break;
    case 'cue.set.completed':
    case 'cue.set.failed':
      state.overlayMorphedToFinish = false;   // SC-rest INV-T6 unlatch
      break;
    case 'cue.pr.achieved':
      if (event.setId != null) state.prFiredSetIds.add(event.setId);
      break;
    case 'cue.confirm.destructive':
      state.pendingConfirmation = true;
      break;
    default:
      break;
  }
  return [dispatch];
}

// ---------------------------------------------------------------------------
// Assertion helpers
// ---------------------------------------------------------------------------
function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (a === null || b === null) return a === b;
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    return a.every((v, i) => deepEqual(v, b[i]));
  }
  if (typeof a === 'object') {
    const ka = Object.keys(a).sort();
    const kb = Object.keys(b).sort();
    if (!deepEqual(ka, kb)) return false;
    return ka.every((k) => deepEqual(a[k], b[k]));
  }
  return false;
}

/// Partial match: every key present in `expected` must match; extra keys in
/// `actual` are ignored (used for logHead/logTail projections).
function matchesPartial(actual, expected) {
  if (expected === null || expected === undefined) return actual === expected;
  if (typeof expected !== 'object') return actual === expected;
  if (Array.isArray(expected)) return deepEqual(actual, expected);
  return Object.keys(expected).every((k) => matchesPartial(actual?.[k], expected[k]));
}

// ---------------------------------------------------------------------------
// Vector runner
// ---------------------------------------------------------------------------
function runVector(fixture, vector) {
  const state = new CueStateMirror(vector.context ?? { appState: 'foreground', silenced: false });
  const firedDispatches = [];

  const checkPending = (label, expected) => {
    if (expected === undefined) return;
    state.pendingConfirmation === expected
      ? pass(`${label}.pendingConfirmation=${expected}`)
      : fail(`${label}: pendingConfirmation=${state.pendingConfirmation} expected ${expected}`);
  };

  vector.steps.forEach((step, i) => {
    const label = `${fixture.fixture}/${vector.id}.step${i + 1}(${step.do}${step.event ? `:${step.event.cue}` : ''})`;
    switch (step.do) {
      case 'setContext': {
        state.context = { ...step.context };
        pass(`${label} → appState=${state.context.appState} silenced=${state.context.silenced}`);
        break;
      }
      case 'resolveConfirmation': {
        state.resolveConfirmation();
        checkPending(label, step.expect?.pendingConfirmation);
        break;
      }
      case 'evaluate': {
        // Optional repeat expansion: `repeat` evaluations, `at` advancing by
        // `atStep` each time (used by the ring-wrap vector).
        const count = step.repeat ?? 1;
        const atStep = step.atStep ?? 0;
        for (let k = 0; k < count; k += 1) {
          const event = { ...step.event, at: step.event.at + k * atStep };
          const before = state.totalEntries;
          const dispatches = evaluate(event, state);
          const entry = state.log[state.log.length - 1];
          if (state.totalEntries !== before + 1) {
            fail(`${label}[${k}]: evaluation appended no log entry (BR-013 violated)`);
            continue;
          }
          const ex = step.expect ?? {};
          let ok = true;
          if (ex.outcome !== undefined && entry.outcome !== ex.outcome) {
            ok = false; fail(`${label}[${k}]: outcome=${entry.outcome} expected ${ex.outcome}`);
          }
          if (ok && ex.reason !== undefined && entry.reason !== ex.reason) {
            ok = false; fail(`${label}[${k}]: reason=${entry.reason} expected ${ex.reason}`);
          }
          if (ok && entry.outcome === 'fired' && dispatches.length !== 1) {
            ok = false; fail(`${label}[${k}]: fired but ${dispatches.length} dispatches`);
          }
          if (ok && entry.outcome !== 'fired' && dispatches.length !== 0) {
            ok = false; fail(`${label}[${k}]: ${entry.outcome} but ${dispatches.length} dispatches`);
          }
          if (ok && ex.dispatch !== undefined && !deepEqual(dispatches[0] ?? null, ex.dispatch)) {
            ok = false;
            fail(`${label}[${k}]: dispatch ${JSON.stringify(dispatches[0])} != expected ${JSON.stringify(ex.dispatch)}`);
          }
          if (ok) {
            if (count > 1) { if (k === 0 || k === count - 1) pass(`${label}[${k}]`); }
            else pass(label);
          }
          if (entry.outcome === 'fired') firedDispatches.push(dispatches[0]);
          checkPending(`${label}[${k}]`, ex.pendingConfirmation);
        }
        break;
      }
      default:
        fail(`${label}: unknown step type ${step.do}`);
    }
  });

  const fin = vector.finalExpect ?? {};
  const vid = `${fixture.fixture}/${vector.id}.final`;
  if (fin.dispatchCount !== undefined) {
    firedDispatches.length === fin.dispatchCount
      ? pass(`${vid}.dispatchCount=${fin.dispatchCount}`)
      : fail(`${vid}: dispatchCount=${firedDispatches.length} expected ${fin.dispatchCount}`);
  }
  if (fin.firedCues !== undefined) {
    const got = firedDispatches.map((d) => d.cue);
    deepEqual(got, fin.firedCues)
      ? pass(`${vid}.firedCues`)
      : fail(`${vid}: firedCues=${JSON.stringify(got)} expected ${JSON.stringify(fin.firedCues)}`);
  }
  if (fin.noBlockingEver) {
    const blockers = firedDispatches.filter((d) => d.blocking);
    blockers.length === 0
      ? pass(`${vid}.noBlockingEver`)
      : fail(`${vid}: ${blockers.length} blocking dispatch(es) on the accept path (BR-011 violated)`);
  }
  if (fin.log !== undefined) {
    deepEqual(state.log, fin.log)
      ? pass(`${vid}.log`)
      : fail(`${vid}: log ${JSON.stringify(state.log)} != expected ${JSON.stringify(fin.log)}`);
  }
  if (fin.logLength !== undefined) {
    state.log.length === fin.logLength
      ? pass(`${vid}.logLength=${fin.logLength}`)
      : fail(`${vid}: logLength=${state.log.length} expected ${fin.logLength}`);
  }
  if (fin.logHead !== undefined) {
    matchesPartial(state.log[0], fin.logHead)
      ? pass(`${vid}.logHead`)
      : fail(`${vid}: logHead ${JSON.stringify(state.log[0])} !~ ${JSON.stringify(fin.logHead)}`);
  }
  if (fin.logTail !== undefined) {
    matchesPartial(state.log.at(-1), fin.logTail)
      ? pass(`${vid}.logTail`)
      : fail(`${vid}: logTail ${JSON.stringify(state.log.at(-1))} !~ ${JSON.stringify(fin.logTail)}`);
  }
  if (fin.overlayMorphedToFinish !== undefined) {
    state.overlayMorphedToFinish === fin.overlayMorphedToFinish
      ? pass(`${vid}.overlayMorphedToFinish=${fin.overlayMorphedToFinish}`)
      : fail(`${vid}: overlayMorphedToFinish=${state.overlayMorphedToFinish} expected ${fin.overlayMorphedToFinish}`);
  }
  if (fin.pendingConfirmation !== undefined) {
    state.pendingConfirmation === fin.pendingConfirmation
      ? pass(`${vid}.pendingConfirmation=${fin.pendingConfirmation}`)
      : fail(`${vid}: pendingConfirmation=${state.pendingConfirmation} expected ${fin.pendingConfirmation}`);
  }
}

// ---------------------------------------------------------------------------
// Source parity — the Swift channel table must carry the same vocabulary.
// (The JS mirror is authoritative for logic; this catches Cue.swift drift.)
// ---------------------------------------------------------------------------
function checkSourceParity() {
  let swift;
  try {
    swift = readFileSync(cueSwiftPath, 'utf8');
  } catch (e) {
    fail(`source-parity: cannot read Cue.swift (${e.message})`);
    return;
  }
  for (const cueId of Object.keys(CHANNELS)) {
    swift.includes(`"${cueId}"`)
      ? pass(`source-parity.cueId.${cueId}`)
      : fail(`source-parity: Cue.swift missing cue id ${cueId}`);
  }
  const visuals = new Set(Object.values(CHANNELS).map((c) => c.visual));
  for (const visual of visuals) {
    swift.includes(`"${visual}"`)
      ? pass(`source-parity.visual.${visual}`)
      : fail(`source-parity: Cue.swift missing visual element ${visual}`);
  }
  for (const haptic of ['success', 'nudge', 'alert', 'celebration']) {
    swift.includes(`case ${haptic}`)
      ? pass(`source-parity.hapticClass.${haptic}`)
      : fail(`source-parity: Cue.swift missing haptic class ${haptic}`);
  }
  for (const kind of PR_PRECEDENCE) {
    swift.includes(`"${kind}"`)
      ? pass(`source-parity.prKind.${kind}`)
      : fail(`source-parity: Cue.swift missing PR kind ${kind}`);
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
function main() {
  checkSourceParity();

  const fx = (name) => JSON.parse(readFileSync(join(fixturesDir, name), 'utf8'));
  const fixtures = [
    '01-taxonomy-fire-once.json',
    '02-dedupe-collapse.json',
    '03-dedupe-boundary.json',
    '04-rest-end-suppressed-post-morph.json',
    '05-rest-end-backgrounded.json',
    '06-silenced-degradation.json',
    '07-first-touch-pr-suppression.json',
    '08-precedence-one-cue-per-set.json',
    '09-drop-no-haptic.json',
    '10-confirm-blocking.json',
    '11-one-tap-accept-never-blocks.json',
    '12-ring-buffer-sequence.json',
  ];
  for (const name of fixtures) {
    const fixture = fx(name);
    if (fixture.contractId !== 'SC-cues@1.0.0') {
      fail(`${name}: contractId=${fixture.contractId} — fixtures must cite SC-cues@1.0.0`);
      continue;
    }
    for (const vector of fixture.vectors) {
      runVector(fixture, vector);
    }
  }

  console.log(`\n${passes} passed, ${failures} failed`);
  if (failures === 0) { console.log('ALL CUES FIXTURES PASS'); process.exit(0); }
  console.error(`${failures} assertion(s) failed`);
  process.exit(1);
}

main();
