-- Migration 0011: body metrics measurement support (SC-settings@1.0.0 §3d, #28).
-- Renumbered 0009→0011 by #32 to give the canonical chain unique identifiers.
--
-- 0001 shipped body_metric with kind CHECK IN ('bodyWeight','bodyFat','weight')
-- and unit CHECK IN ('kg','lb','pct'). #28's BodyMetrics surface requires a
-- third kind — 'measurement' (any string name + numeric value + unit, e.g.
-- "Waist 84 cm") — plus free-form units. SQLite cannot ALTER a CHECK, so this
-- migration uses the same table-rebuild pattern as 0007_progression_full.sql
-- and 0009_personal_records.sql: behavior-additive, no row ever lost.
--
-- Changes vs 0001 shape:
--   - kind CHECK widened to ('bodyWeight','bodyFat','measurement'); the legacy
--     'weight' synonym is REMAPPED to 'bodyWeight' in the copy below (INV-ST6).
--   - label TEXT added (0011): free name, REQUIRED for kind='measurement',
--     NULL otherwise (SC-settings BR-006).
--   - unit widened to free TEXT: legality per kind is application-enforced
--     (bodyWeight ∈ kg|lb; bodyFat = pct; measurement = any non-empty unit).
--   - trend indexes for the date-descending list (BR-007).
--
-- No renames/drops of columns, no edits to 0001–0010. app_setting is untouched
-- (already created by 0008_rest_fields.sql per SC-rest §3d — verified present).

-- Step 1: canonical table with the SC-settings §3b shape.
CREATE TABLE IF NOT EXISTS body_metric_v2 (
    id          TEXT PRIMARY KEY NOT NULL,
    kind        TEXT NOT NULL CHECK (kind IN ('bodyWeight','bodyFat','measurement')),
    label       TEXT,
    value       REAL NOT NULL,
    unit        TEXT NOT NULL,
    recordedAt  TEXT NOT NULL,
    createdAt   TEXT NOT NULL,
    updatedAt   TEXT NOT NULL,
    deletedAt   TEXT
);

-- Step 2: copy legacy rows verbatim except the kind remap. 'weight' was 0001's
-- duplicate spelling of body weight (Models.swift carried both enum cases);
-- every other field passes through untouched, tombstones included.
INSERT INTO body_metric_v2 (id, kind, label, value, unit, recordedAt, createdAt, updatedAt, deletedAt)
SELECT id,
       CASE WHEN kind = 'weight' THEN 'bodyWeight' ELSE kind END,
       NULL,
       value, unit, recordedAt, createdAt, updatedAt, deletedAt
FROM body_metric;

-- Step 3: swap tables. The pre-remap shape is preserved under the legacy name
-- (0009 precedent) — it stays in every full-file export (SC-settings INV-ST3).
ALTER TABLE body_metric RENAME TO body_metric__legacy_0001;
ALTER TABLE body_metric_v2 RENAME TO body_metric;

-- Step 4: trend-list indexes (BR-007: recordedAt-descending, live rows only).
CREATE INDEX IF NOT EXISTS body_metric_kind_recorded_idx
    ON body_metric(kind, recordedAt DESC)
    WHERE deletedAt IS NULL;
CREATE INDEX IF NOT EXISTS body_metric_recorded_idx
    ON body_metric(recordedAt DESC)
    WHERE deletedAt IS NULL;
