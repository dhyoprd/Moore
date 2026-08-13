-- Migration 0009: personal records canonical shape (SC-prs@1.0.0, #26).
-- Renumbered 0008→0009 by #32 to give the canonical chain unique identifiers.
-- Heals 0001's legacy `personal_record` CHECK ('weight','volume','rep') + missing
-- `sessionId` into the #3-canonical `{max_1rm, max_volume, max_reps, max_duration}`
-- + sessionId shape. Table-rebuild pattern (identical to 0007_progression_full.sql):
-- SQLite cannot ALTER a CHECK constraint; additive-only behavior (rows never lost).
--
-- Legacy kind mapping (INV-PR1's closed 4-enum is the writer side; readers accept
-- only those four): weight → max_1rm, volume → max_volume, rep → max_reps.
-- sessionId is backfilled via the setId → completed_set join; unresolved rows use
-- the '' sentinel (readers filter on it; the badge query tolerates it).

CREATE TABLE IF NOT EXISTS personal_record_v2 (
    id          TEXT PRIMARY KEY NOT NULL,
    exerciseId  TEXT NOT NULL REFERENCES exercise(id),
    sessionId   TEXT NOT NULL,                       -- resolved below; '' sentinel for legacy drift
    setId       TEXT REFERENCES completed_set(id),
    kind        TEXT NOT NULL CHECK (kind IN ('max_1rm','max_volume','max_reps','max_duration')),
    value       REAL NOT NULL,
    achievedAt  TEXT NOT NULL,
    createdAt   TEXT NOT NULL,
    updatedAt   TEXT NOT NULL,
    deletedAt   TEXT
);

-- Copy legacy rows across, mapping kind + backfilling sessionId via setId.
-- Rows whose setId is NULL or whose joined session is NULL keep '' for sessionId.
INSERT INTO personal_record_v2 (id, exerciseId, sessionId, setId, kind, value, achievedAt, createdAt, updatedAt, deletedAt)
SELECT pr.id,
       pr.exerciseId,
       COALESCE(cs.sessionId, ''),
       pr.setId,
       CASE pr.kind
           WHEN 'weight' THEN 'max_1rm'
           WHEN 'volume' THEN 'max_volume'
           WHEN 'rep'    THEN 'max_reps'
           ELSE pr.kind
       END,
       pr.value,
       pr.achievedAt,
       pr.createdAt,
       pr.updatedAt,
       pr.deletedAt
FROM personal_record pr
LEFT JOIN completed_set cs ON cs.id = pr.setId;

ALTER TABLE personal_record RENAME TO personal_record__legacy_0001;
ALTER TABLE personal_record_v2 RENAME TO personal_record;

CREATE INDEX IF NOT EXISTS personal_record_exercise_idx   ON personal_record(exerciseId)       WHERE deletedAt IS NULL;
CREATE INDEX IF NOT EXISTS personal_record_session_idx    ON personal_record(sessionId)        WHERE deletedAt IS NULL;
CREATE INDEX IF NOT EXISTS personal_record_kind_ex_idx    ON personal_record(exerciseId, kind) WHERE deletedAt IS NULL;
