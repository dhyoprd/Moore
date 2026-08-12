-- Migration 0001: core schema for the nine entities (#3 / SC-foundation@1.0.0)
-- Additive-only starting point: all CREATE TABLE only.
-- Convention: id = UUID v4 string, createdAt/updatedAt/deletedAt = ISO-8601 UTC text,
-- deletedAt NULL while live (tombstone when set, BR-003).

CREATE TABLE folder (
    id          TEXT PRIMARY KEY NOT NULL,
    name        TEXT NOT NULL,
    createdAt   TEXT NOT NULL,
    updatedAt   TEXT NOT NULL,
    deletedAt   TEXT
);

CREATE TABLE exercise (
    id                      TEXT PRIMARY KEY NOT NULL,
    name                    TEXT NOT NULL,
    exerciseType            TEXT NOT NULL CHECK (exerciseType IN ('strength','cardio','custom')),
    equipmentSlug           TEXT,
    primaryMuscleId         TEXT,
    secondaryMuscleIdsJson  TEXT,
    instructions            TEXT,
    isCustom                INTEGER NOT NULL DEFAULT 0 CHECK (isCustom IN (0,1)),
    createdAt               TEXT NOT NULL,
    updatedAt               TEXT NOT NULL,
    deletedAt               TEXT
);

CREATE TABLE routine (
    id          TEXT PRIMARY KEY NOT NULL,
    folderId    TEXT REFERENCES folder(id),
    name        TEXT NOT NULL,
    sortOrder   INTEGER NOT NULL DEFAULT 0,
    createdAt   TEXT NOT NULL,
    updatedAt   TEXT NOT NULL,
    deletedAt   TEXT
);

CREATE TABLE planned_set (
    id              TEXT PRIMARY KEY NOT NULL,
    routineId       TEXT NOT NULL REFERENCES routine(id),
    exerciseId      TEXT NOT NULL REFERENCES exercise(id),
    sortOrder       INTEGER NOT NULL,
    plannedWeight   REAL,
    plannedReps     INTEGER,
    plannedDuration INTEGER,
    createdAt       TEXT NOT NULL,
    updatedAt       TEXT NOT NULL,
    deletedAt       TEXT
);
CREATE INDEX planned_set_routine_idx   ON planned_set(routineId)   WHERE deletedAt IS NULL;
CREATE INDEX planned_set_exercise_idx  ON planned_set(exerciseId)  WHERE deletedAt IS NULL;

CREATE TABLE workout_session (
    id          TEXT PRIMARY KEY NOT NULL,
    startedAt   TEXT NOT NULL,
    endedAt     TEXT,
    createdAt   TEXT NOT NULL,
    updatedAt   TEXT NOT NULL,
    deletedAt   TEXT
);

CREATE TABLE completed_set (
    id              TEXT PRIMARY KEY NOT NULL,
    sessionId       TEXT NOT NULL REFERENCES workout_session(id),
    exerciseId      TEXT NOT NULL REFERENCES exercise(id),
    sortOrder       INTEGER NOT NULL,
    plannedWeight   REAL,
    plannedReps     INTEGER,
    plannedDuration INTEGER,
    actualWeight    REAL,
    actualReps      INTEGER,
    actualDuration  INTEGER,
    status          TEXT NOT NULL CHECK (status IN ('planned','completed','failed','dropped')),
    completedAt     TEXT,
    createdAt       TEXT NOT NULL,
    updatedAt       TEXT NOT NULL,
    deletedAt       TEXT
);
CREATE INDEX completed_set_session_idx  ON completed_set(sessionId)  WHERE deletedAt IS NULL;
CREATE INDEX completed_set_exercise_idx ON completed_set(exerciseId) WHERE deletedAt IS NULL;

CREATE TABLE personal_record (
    id          TEXT PRIMARY KEY NOT NULL,
    exerciseId  TEXT NOT NULL REFERENCES exercise(id),
    setId       TEXT REFERENCES completed_set(id),
    kind        TEXT NOT NULL CHECK (kind IN ('weight','volume','rep')),
    value       REAL NOT NULL,
    achievedAt  TEXT NOT NULL,
    createdAt   TEXT NOT NULL,
    updatedAt   TEXT NOT NULL,
    deletedAt   TEXT
);
CREATE INDEX personal_record_exercise_idx ON personal_record(exerciseId) WHERE deletedAt IS NULL;

CREATE TABLE body_metric (
    id          TEXT PRIMARY KEY NOT NULL,
    kind        TEXT NOT NULL CHECK (kind IN ('bodyWeight','bodyFat','weight')),
    value       REAL NOT NULL,
    unit        TEXT NOT NULL CHECK (unit IN ('kg','lb','pct')),
    recordedAt  TEXT NOT NULL,
    createdAt   TEXT NOT NULL,
    updatedAt   TEXT NOT NULL,
    deletedAt   TEXT
);
