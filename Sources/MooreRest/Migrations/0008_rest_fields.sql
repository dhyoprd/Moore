-- Migration 0008: rest-timer configuration fields (SC-rest@1.0.0, #23).
-- Renumbered 0007→0008 by #32 to give the canonical chain unique identifiers.
-- Purely additive per INV-4 / SC-foundation BR-001: two new nullable columns,
-- one new singleton settings table, one idempotent defaults seed.
--
-- Level 2 of #9's hierarchy (exercise.defaultRestSec) is authored by #20's
-- 0004_exercise_library.sql (rewritten by #32 against the real 0001 shape) and
-- is NOT re-added here — see §3a of the contract.

-- Level 1: per-set override slot. NULL = inherit down the chain (BR-001).
-- #22's session materialization snapshot-copies this onto completed_set like
-- every other planned field; this migration owns only the blueprint column.
ALTER TABLE planned_set ADD COLUMN restDurationSec INTEGER;

-- Level 3: per-routine override slot. NULL = inherit (BR-001).
ALTER TABLE routine ADD COLUMN restSec INTEGER;

-- Level 4: global defaults storage (singleton key-value rows).
CREATE TABLE IF NOT EXISTS app_setting (
    key         TEXT PRIMARY KEY NOT NULL,
    value       TEXT NOT NULL,
    updatedAt   TEXT NOT NULL
);

-- INV-S2: seed the two #9 v1 defaults if absent. INSERT OR IGNORE so a
-- user-changed value is never reset by re-migration. Compound 180s, isolation
-- (and every duration-metric exercise) 90s.
INSERT OR IGNORE INTO app_setting (key, value, updatedAt) VALUES
    ('defaultRestCompoundSec',  '180', strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    ('defaultRestIsolationSec', '90',  strftime('%Y-%m-%dT%H:%M:%fZ','now'));
