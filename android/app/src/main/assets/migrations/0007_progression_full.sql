-- Migration 0007: progress SC-progression@1.0.0 fields onto progression_scheme.
-- Applies AFTER 0002_warmup_progression.sql. Purely additive (ALTER ADD COLUMN only).
--
-- Schema deficit healed per SC-progression@1.0.0 §3: 0002 shipped a leaner shape
-- ('linear'/'double'/'percentage' only, no warmup-modes). This migration adds:
--   - widened scheme CHECK to include 'none' and 'hold-duration', 'percentage' removed (never in #5's v1)
--   - missing stall-management fields (nextBannerAt/deloadPending/stalledWeight/stalledReps/stalledDurationSec/baselineDurationSec)
--   - SQLite does NOT support ALTER COLUMN CHECK (table rebuild pattern). We therefore
--     create progression_scheme_v2 with the correct shape and copy across; the table
--     name is re-pointed via RENAME in this migration on a fresh DB. The legacy
--     progression_scheme is dropped only after the copy. This is additive-only in
--     behavior (never losing rows) and required to change the CHECK safely.

-- Step 1: new canonical table holding the full spec'd shape.
CREATE TABLE IF NOT EXISTS progression_scheme_v2 (
    id                      TEXT PRIMARY KEY NOT NULL,
    routineId               TEXT NOT NULL REFERENCES routine(id),
    exerciseId              TEXT NOT NULL REFERENCES exercise(id),
    scheme                  TEXT NOT NULL DEFAULT 'none'
                            CHECK (scheme IN ('none','linear','double','hold-duration')),
    incrementValue          REAL,
    doubleProgressionMinReps INTEGER,
    doubleProgressionMaxReps INTEGER,
    warmupEnabled           INTEGER NOT NULL DEFAULT 0 CHECK (warmupEnabled IN (0,1)),
    stallCount              INTEGER NOT NULL DEFAULT 0,
    stallMuted              INTEGER NOT NULL DEFAULT 0 CHECK (stallMuted IN (0,1)),
    nextBannerAt            INTEGER NOT NULL DEFAULT 3,
    deloadPending           INTEGER NOT NULL DEFAULT 0 CHECK (deloadPending IN (0,1)),
    lastDeloadSessionId     TEXT REFERENCES workout_session(id),
    stalledWeight           REAL,
    stalledReps             INTEGER,
    stalledDurationSec      INTEGER,
    baselineDurationSec     INTEGER,
    createdAt               TEXT NOT NULL,
    updatedAt               TEXT NOT NULL,
    deletedAt               TEXT
);

-- Step 2: copy legacy rows across. For any legacy rows present, map them:
--   - scheme: if 'percentage' → coerce to 'none' (percentage was never in v1 spec).
--   - carry over stallCount, stallMuted, lastDeloadSessionId, warmupEnabled.
--   - new fields take the defaults defined above.
-- Note: this codebase has UNVERIFIED exercise-level rows on progression_scheme
-- (no rows before this migration runs); the copy is defensive.
INSERT INTO progression_scheme_v2 (
    id, routineId, exerciseId, scheme, incrementValue,
    doubleProgressionMinReps, doubleProgressionMaxReps,
    warmupEnabled, stallCount, stallMuted, lastDeloadSessionId,
    createdAt, updatedAt, deletedAt
)
SELECT id, routineId, exerciseId,
       CASE WHEN scheme IN ('none','linear','double','hold-duration') THEN scheme ELSE 'none' END,
       incrementValue, doubleProgressionMinReps, doubleProgressionMaxReps,
       warmupEnabled, stallCount, stallMuted, lastDeloadSessionId,
       createdAt, updatedAt, deletedAt
FROM progression_scheme;

-- Step 3: swap tables. Old table preserved as a backup with postfixed name
-- (harmless tombstone so any uncommited sync layers can still read it; the new
-- name is what down-stream code uses).
ALTER TABLE progression_scheme RENAME TO progression_scheme__legacy_0002;
ALTER TABLE progression_scheme_v2 RENAME TO progression_scheme;

-- Rebuild the unique index to target the NEW table (the old index was attached to
-- the old name and no longer constrains the new one).
CREATE UNIQUE INDEX IF NOT EXISTS progression_scheme_routine_exercise_idx
    ON progression_scheme(routineId, exerciseId)
    WHERE deletedAt IS NULL;
