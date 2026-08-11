-- Migration 0005: routines + folders seam for SC-routines@1.0.0.
-- Purely additive per INV-4 (SC-foundation@1.0.0 BR-001).
--
-- The `folder`, `routine`, and `planned_set` tables are owned by #19's migration
-- 0001_core.sql (SC-foundation@1.0.0 §3a). This migration therefore creates no
-- new tables in the normal case; it exists to (a) register this contract's claim
-- on the seam, (b) add the Home-grouping index on routine(folderId), and
-- (c) stay lawfully re-runnable / fresh-install-safe by using IF NOT EXISTS so a
-- database built without 0001 still gains the tables with the identical 0001 shape.
--
-- Convention: id = UUID v4 string (INV-1); createdAt/updatedAt = ISO-8601 UTC text;
-- deletedAt NULL while live (tombstone when set, INV-3).

CREATE TABLE IF NOT EXISTS folder (
    id          TEXT PRIMARY KEY NOT NULL,
    name        TEXT NOT NULL,
    createdAt   TEXT NOT NULL,
    updatedAt   TEXT NOT NULL,
    deletedAt   TEXT
);

CREATE TABLE IF NOT EXISTS routine (
    id          TEXT PRIMARY KEY NOT NULL,
    folderId    TEXT REFERENCES folder(id),
    name        TEXT NOT NULL,
    sortOrder   INTEGER NOT NULL DEFAULT 0,
    createdAt   TEXT NOT NULL,
    updatedAt   TEXT NOT NULL,
    deletedAt   TEXT
);

CREATE TABLE IF NOT EXISTS planned_set (
    id              TEXT PRIMARY KEY NOT NULL,
    routineId       TEXT NOT NULL REFERENCES routine(id),
    exerciseId      TEXT NOT NULL,
    sortOrder       INTEGER NOT NULL,
    plannedWeight   REAL,
    plannedReps     INTEGER,
    plannedDuration INTEGER,
    createdAt       TEXT NOT NULL,
    updatedAt       TEXT NOT NULL,
    deletedAt       TEXT
);

-- Home surface (SC-routines §5) reads groups ORDER BY routine.folderId; this index
-- serves the folder/grouping query on live rows. Supports BR-006 ordering + the
-- BR-003 folder-delete re-scoped-to-unfiled read.
CREATE INDEX IF NOT EXISTS routine_folder_idx
    ON routine(folderId)
    WHERE deletedAt IS NULL;

CREATE INDEX IF NOT EXISTS planned_set_routine_live_idx
    ON planned_set(routineId)
    WHERE deletedAt IS NULL;
