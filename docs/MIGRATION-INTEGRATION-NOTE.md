# Migration integration note — #19 ↔ #20 schema drift

## Drift discovered during #21's implementation

| Column family | #19 (foundation) | #20 (exercise-library) | Status |
|---|---|---|---|
| `exercise.exerciseType` (`strength \| cardio \| custom`) | ✔ present | absent (uses `isCustom` boolean only) | #19's form is canonical |
| `exercise.category` (compound \| isolation \| …) | absent | ✔ required by #9 for rest-default dispatch | **missing** — must be added |
| `exercise.defaultMetric` (reps \| duration) | absent | ✔ required by #3 | **missing** — must be added |
| `exercise.defaultRestSec` | absent | ✔ required by #9 | **missing** — must be added |
| `exercise.name_normalized` (match helper) | absent | ✔ required by #15 (import matching) | **missing** — must be added |

**Why it happened:** #19 and #20 ran in parallel. #19 shipped first with a lean exercise table; #20 authored its behavior against a slightly different base assumption set. The `Migrations-DEPENDS-ON-19.md` file in `Sources/MooreExercises/` already half-documents this from the #20 side.

## Resolution path

1. At integration time, **#20's `0004_exercise_library.sql` MUST be rewritten** to be `ALTER TABLE exercise ADD COLUMN …` statements against #19's base table shape (which only has `exerciseType`, `equipmentSlug`, etc.). The rewrite lives on the integration branch.
2. Column renames in the rewrite (none needed — #19 uses snake_case SQL which already matches; the DRIFT is additional columns only, no name conflicts).
3. After rewriting, re-run both verifiers in this order: `VerifyMigrations.mjs` (foundation) → `VerifyExerciseLibrary.mjs` (#20's layer) → `VerifyRoutines.mjs` (this ticket). All three must pass.
4. Once integration lands, retire this file — the merge commit will be the record.

## Convenience for the integrator

`feat/20-exercise-library` was merged into this worktree via `git merge --no-ff feat/20-exercise-library` (no conflict — the trees are disjoint). The Package.swift currently carries both workspace folders; when `0004` is rewritten, it must remain idempotent against a foundation-only DB.
