-- Migration 0012: self-validation metrics storage (ticket #43).
-- The 8-week gate of #4's activation trigger becomes measurable: this migration
-- stores the TWO inputs the gate derives from — nothing derived is stored
-- (SC-foundation §3c / SC-analytics INV-A1 still govern: every metric recomputes
-- from these rows + completed_set/workout_session at read time):
--
--   1. app_open_event — one append-only row per app foreground (the retention
--      signal: "app installed and opened regularly"). Events are never updated
--      and have no user-reachable delete path, so per SC-foundation §3b they
--      carry createdAt only (no updatedAt/deletedAt) — same append-only shape
--      rationale as an event timeline.
--   2. validation_baseline — the Hevy baseline for the logging-speed comparison.
--      A dated measurement (value + unit + recordedAt), NOT a timeless setting,
--      so it is a small table with the full sync-ready shape (UUID id, updatedAt,
--      tombstone) instead of an app_setting k/v row; one live row per metricKey
--      via the partial unique index (importKey dedupe precedent, BR-007).
--
-- Purely additive per INV-4 / SC-foundation BR-001: CREATE TABLE + CREATE INDEX only.

CREATE TABLE app_open_event (
    id        TEXT PRIMARY KEY NOT NULL,
    openedAt  TEXT NOT NULL,
    createdAt TEXT NOT NULL
);
CREATE INDEX app_open_event_openedAt_idx ON app_open_event(openedAt);

CREATE TABLE validation_baseline (
    id         TEXT PRIMARY KEY NOT NULL,
    metricKey  TEXT NOT NULL,
    value      REAL NOT NULL,
    unit       TEXT NOT NULL,
    recordedAt TEXT NOT NULL,
    createdAt  TEXT NOT NULL,
    updatedAt  TEXT NOT NULL,
    deletedAt  TEXT
);
CREATE UNIQUE INDEX validation_baseline_key_idx ON validation_baseline(metricKey) WHERE deletedAt IS NULL;
