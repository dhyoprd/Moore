-- Migration 0004: exercise library columns (SC-exercises@1.0.0).
--
-- REWRITTEN for #32 against the REAL SC-foundation@1.0.0 0001_core.sql shape.
-- The original 0004 assumed a snake_case base table (category / default_metric /
-- equipment / is_custom / created_at / ... ) that #19 never shipped; that drift is
-- resolved here and docs/MIGRATION-INTEGRATION-NOTE.md is retired.
--
-- 0001 created `exercise` with these camelCase columns:
--   id, name, exerciseType, equipmentSlug, primaryMuscleId,
--   secondaryMuscleIdsJson, instructions, isCustom, createdAt, updatedAt, deletedAt
-- It does NOT yet have category / defaultMetric / defaultRestSec / name_normalized.
-- This migration is the ONLY thing that adds them — purely additive per BR-001,
-- never renaming or dropping an existing column. Idempotency is provided by the
-- migration tracker (each identifier applies once); the statements below use
-- IF NOT EXISTS / guarded backfill so a re-run on an already-migrated DB is safe
-- where SQLite allows it.

-- BR-004 category (SC-exercises §3b enum). Drives rest-default dispatch (#9), the
-- progression increment rule (#24 BR-009), and the Analytics muscle split (#27
-- BR-004). NULL = unclassified (customs the user never categorized).
ALTER TABLE exercise ADD COLUMN category TEXT;

-- #3 default metric: 'reps' or 'duration'. NULL = unset (the seeder populates it
-- for built-ins). CHECK treats NULL as passing, so pre-existing rows stay valid.
ALTER TABLE exercise ADD COLUMN defaultMetric TEXT CHECK (defaultMetric IN ('reps','duration'));

-- BR-009: per-exercise default rest override slot, in seconds. NULL = no override
-- (the rest hierarchy keeps falling through to routine/global defaults, #23 BR-001).
ALTER TABLE exercise ADD COLUMN defaultRestSec INTEGER;

-- BR-001: materialized normalized name for matching/dedupe. Plain TEXT, not a
-- SQLite GENERATED column, because BR-001 includes interior-whitespace collapse
-- which SQLite lacks a native function for; the application layer maintains it on
-- every write. One-time backfill for rows that pre-date this column: lowercases
-- and trims (interior runs are collapsed by the app on next mutation).
ALTER TABLE exercise ADD COLUMN name_normalized TEXT;
UPDATE exercise SET name_normalized = LOWER(TRIM(name)) WHERE name_normalized IS NULL;

-- BR-003 search support: index on the materialized normalized name (live rows).
-- Column is camelCase `deletedAt` per 0001, NOT snake_case `deleted_at`.
CREATE INDEX IF NOT EXISTS idx_exercise_name_normalized
    ON exercise(name_normalized)
    WHERE deletedAt IS NULL;

-- BR-004 category filter support (live rows).
CREATE INDEX IF NOT EXISTS idx_exercise_category
    ON exercise(category)
    WHERE deletedAt IS NULL;
