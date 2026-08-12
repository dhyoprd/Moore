-- Migration 0006: link workout sessions to the routine they were started from.
-- Purely additive per INV-4 (SC-foundation@1.0.0 BR-001).
--
-- Schema deficit closed: SC-foundation 0001 created `workout_session` WITHOUT a
-- routineId column, but SC-routines' Home derivations (RoutineRow.lastUsedAt, the
-- lifecycle draft→active transition, the quick-resume card's routine name) all
-- require knowing which routine a session was started from. Ad-hoc "Start empty"
-- sessions have no routine → the column is NULL.

ALTER TABLE workout_session ADD COLUMN routineId TEXT REFERENCES routine(id);

-- Serves the per-routine lastUsedAt / last-session-stats aggregate (SC-routines §5).
CREATE INDEX IF NOT EXISTS workout_session_routine_idx
    ON workout_session(routineId)
    WHERE deletedAt IS NULL;
