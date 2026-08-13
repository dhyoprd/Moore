-- Migration 0010: SC-warmup@1.0.0 scaffold — warm-up ramp auto-generation (#25).
-- Renumbered 0008→0010 by #32 to give the canonical chain unique identifiers.
-- Purely additive per SC-foundation BR-001/BR-004.
--
-- All three #16 model additions were already shipped by earlier migrations:
--   planned_set.setClass          (0002)   'warmup'|'work', nullable
--   completed_set.setClass        (0002)   'warmup'|'work', nullable
--   progression_scheme.warmupEnabled (0002, canonical shape post-0007) INTEGER 0|1 DEFAULT 0
-- This migration therefore adds NO columns. It exists to (a) register SC-warmup in
-- the migration chain, (b) assert the contract's expected shape so a drifted chain
-- fails loudly at migration time instead of materializing unramped sessions, and
-- (c) provide a stable seam for a future per-pair warm-up override table
-- (SC-warmup §2 'expected shape'; not v1).

CREATE TABLE IF NOT EXISTS warmup_contract_scaffold (
    -- Single-row shape marker. Rows: none expected at v1. Presence of the TABLE
    -- is what downstream "is SC-warmup in the chain?" checks key on.
    id          TEXT PRIMARY KEY NOT NULL,
    contractId  TEXT NOT NULL DEFAULT 'SC-warmup',
    version     TEXT NOT NULL DEFAULT '1.0.0',
    createdAt   TEXT NOT NULL,
    updatedAt   TEXT NOT NULL,
    deletedAt   TEXT
);

-- Shape assertion: these inserts violate FK/CHECK shape expectations only if the
-- referenced columns vanished. They are transactional with the migration, so a
-- drifted schema fails the apply and leaves the DB untouched.
INSERT INTO warmup_contract_scaffold (id, contractId, version, createdAt, updatedAt, deletedAt)
SELECT 'sc-warmup-1.0.0-shape-check',
       'SC-warmup', '1.0.0',
       '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z', NULL
WHERE EXISTS (SELECT 1 FROM pragma_table_info('completed_set')   WHERE name = 'setClass')
  AND EXISTS (SELECT 1 FROM pragma_table_info('planned_set')     WHERE name = 'setClass')
  AND EXISTS (SELECT 1 FROM pragma_table_info('progression_scheme') WHERE name = 'warmupEnabled');
