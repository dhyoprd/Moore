-- Migration 0003: Hevy CSV import columns on WorkoutSession (#15).
-- Purely additive per BR-001.

ALTER TABLE workout_session ADD COLUMN name         TEXT;
ALTER TABLE workout_session ADD COLUMN notes        TEXT;
ALTER TABLE workout_session ADD COLUMN importSource TEXT;
ALTER TABLE workout_session ADD COLUMN importKey    TEXT;

-- BR-007: re-import with the same importKey must dedupe, not duplicate.
-- Partial index keeps hand-entered sessions (importKey IS NULL) out of it.
CREATE UNIQUE INDEX workout_session_importkey_idx
    ON workout_session(importKey)
    WHERE importKey IS NOT NULL;
