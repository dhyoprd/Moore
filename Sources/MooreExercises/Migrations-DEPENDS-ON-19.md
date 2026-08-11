# Merger's note: integration with #19 (SC-foundation)

This module (`MooreExercises`, ticket #20) was written against **assumed** #19 schema.
#19 was not yet committed to `main` when this worktree was branched, so migration
`0004_exercise_library.sql` layers additively on top of a base `exercise` table whose
exact DDL could not be read from source at write time.

## What this module assumes #19 created

Table `exercise` (owned by Migration 0001 of `SC-foundation@1.0.0`) with, at minimum:

| Column            | Type        | Notes                                        |
|-------------------|-------------|----------------------------------------------|
| `id`              | TEXT PK     | UUID for customs; stable slug for built-ins  |
| `name`            | TEXT NOT NULL | display name (user casing preserved)       |
| `category`        | TEXT        | raw enum string (SC-exercises §3b)           |
| `default_metric`  | TEXT        | `reps` or `duration`                         |
| `equipment`       | TEXT        | raw enum string                              |
| `is_custom`       | INTEGER     | 0 for built-ins, 1 for customs                |
| `created_at`      | TEXT        | ISO-8601 UTC                                 |
| `updated_at`      | TEXT        | ISO-8601 UTC                                 |
| `deleted_at`      | TEXT NULL   | tombstone (incl. this col was already in #3) |

(`#3`'s entity definition agreed on all of the above; if any column was dropped or
renamed in #19's final migration, this is the conflict point.)

## What migration 0004 adds (owned by SC-exercises@1.0.0)

- `name_normalized TEXT` — BR-001 materialized key; indexed.
- `default_rest_sec INTEGER NULL` — rest override slot per #9.
- `idx_exercise_name_normalized`, `idx_exercise_category` — partial (filtered)
  indexes excluding tombstoned rows.

## Conflict risk checklist for the integration branch

1. **If #19 already created `name_normalized` or `default_rest_sec`** (unlikely: both
   are #20's columns): change the two `ALTER TABLE` statements into no-ops guarded by
   a `SELECT 1 FROM pragma_table_info('exercise') WHERE name = '...'` pre-flight, or
   drop the duplicate line. Do NOT keep both.
2. **If #19's `exercise` table lacks any assumed column** (e.g. `is_custom` landed on
   a different name): add an `ALTER TABLE exercise ADD COLUMN …` for whatever is
   missing; the DAO layer (Sources/MooreExercises/) reads columns by these names.
3. **Migration ordering**: 0001–0003 are #19's; 0004 is this module's. The integrator
   must register them in that order in a single `DatabaseMigrator`. GRDB's migrator
   applies in registration order, so as long as `Sources/MooreExercises/Migrations/0004_*.sql`
   is registered after the three foundation migrations, no code change is needed.
4. **Seed ownership**: `Sources/MooreExercises/Seed/builtin-library.json` is seeded by
   `ExerciseLibrary.seedBuiltInsIfNeeded(seedURL:)` (idempotent). No foundation code
   needs to know about it.
