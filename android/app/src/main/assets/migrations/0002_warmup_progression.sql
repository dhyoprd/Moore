-- Migration 0002: warm-up ramp fields (#16) + ProgressionScheme entity (#5).
-- Purely additive per BR-001: two new nullable/const-default columns, one new table.

ALTER TABLE planned_set   ADD COLUMN setClass TEXT CHECK (setClass IN ('warmup','work'));
ALTER TABLE completed_set ADD COLUMN setClass TEXT CHECK (setClass IN ('warmup','work'));
-- TODO(#31-port): the CHECK-with-DEFAULT pattern below is portable SQLite; Room
-- executes identically. If a future migration needs a function default we split
-- ADD COLUMN (no default) + UPDATE rather than rely on ALTER TABLE ... DEFAULT fn.

CREATE TABLE progression_scheme (
    id                          TEXT PRIMARY KEY NOT NULL,
    routineId                   TEXT NOT NULL REFERENCES routine(id),
    exerciseId                  TEXT NOT NULL REFERENCES exercise(id),
    scheme                      TEXT NOT NULL CHECK (scheme IN ('linear','double','percentage')),
    incrementValue              REAL,
    doubleProgressionMinReps    INTEGER,
    doubleProgressionMaxReps    INTEGER,
    warmupEnabled               INTEGER NOT NULL DEFAULT 0 CHECK (warmupEnabled IN (0,1)),
    stallCount                  INTEGER NOT NULL DEFAULT 0,
    stallMuted                  INTEGER NOT NULL DEFAULT 0 CHECK (stallMuted IN (0,1)),
    lastDeloadSessionId         TEXT REFERENCES workout_session(id),
    createdAt                   TEXT NOT NULL,
    updatedAt                   TEXT NOT NULL,
    deletedAt                   TEXT
);
CREATE UNIQUE INDEX progression_scheme_routine_exercise_idx
    ON progression_scheme(routineId, exerciseId)
    WHERE deletedAt IS NULL;
