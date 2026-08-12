-- Migration 0004: exercise library columns (SC-exercises@1.0.0)
--
-- ASSUMPTION: #19's migrations 0001–0003 have already created the `exercise` table
-- with at minimum: id (TEXT PRIMARY KEY), name (TEXT NOT NULL), category (TEXT),
-- default_metric (TEXT), equipment (TEXT), is_custom (INTEGER), created_at (TEXT),
-- updated_at (TEXT), deleted_at (TEXT NULL).
--
-- If #19's Migration 0001 differs from that shape in any way, this migration is the
-- ONLY thing to adjust — never edit 0001–0003.
--
-- This migration is ADDITIVE only (per #4's additive-only rule): it adds columns and
-- indexes; it never renames or drops existing ones.

-- BR-001: materialized normalized name for matching/dedupe. Plain TEXT, not a SQLite
-- GENERATED column, because BR-001 includes interior-whitespace collapse which SQLite
-- lacks a native function for; the application layer maintains it on every write.
ALTER TABLE exercise ADD COLUMN name_normalized TEXT;

-- One-time backfill for rows that may already exist (e.g. created by an earlier dev
-- build before this column existed). Lowercases and trims; interior runs are NOT
-- collapsed (that requires app logic) — harmless because no such rows should exist
-- in production; if any slip in, the app rewrites them on next mutation.
UPDATE exercise SET name_normalized = LOWER(TRIM(name)) WHERE name_normalized IS NULL;

-- NOT NULL is enforced at the application layer and via backfill above; SQLite ALTER
-- cannot add NOT NULL without a default, so no NOT NULL constraint here. The DAO
-- rejects any write with a null name_normalized.

-- BR-009: per-exercise default rest override slot, in seconds. NULL = no override.
ALTER TABLE exercise ADD COLUMN default_rest_sec INTEGER;

-- BR-003 search support: index on the materialized normalized name.
CREATE INDEX IF NOT EXISTS idx_exercise_name_normalized
    ON exercise(name_normalized)
    WHERE deleted_at IS NULL;

-- BR-004 category filter support.
CREATE INDEX IF NOT EXISTS idx_exercise_category
    ON exercise(category)
    WHERE deleted_at IS NULL;
