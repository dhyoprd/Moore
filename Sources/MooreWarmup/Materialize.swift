// contractId: SC-warmup @1.0.0
// Post-stamp warm-up application — the buddy pass to MooreWorkout/Materialize.swift.
// Runs AFTER MooreWorkout.Materialize.startSession has copied the routine's
// (suggest-stamped) work rows, inside the caller's transaction boundary per
// SC-workout-logging BR-009, and BEFORE the session is presented.
//
//   stamp:   SC-workout-logging §5   — blueprint → completed_set work rows
//   warm-up: this file               — derived rows prepended per gated exercise
//
// Failure isolation: a per-pair derivation failure is contained to that pair
// (it simply gets no ramp) and never rolls back the session (BR-002/BR-008);
// only a failure of the enclosing session write propagates.

import Foundation
import GRDB

public enum WarmupMaterialize {

    /// The caller (Home / Start CTA) invokes this immediately after
    /// `Materialize.startSession` returns, within the same write batch when the
    /// host composes one; standalone invocation is equally lawful (BR-008 cares
    /// about the session's stored shape, not the transaction envelope).
    ///
    /// - Parameters:
    ///   - sessionId: the freshly materialized session.
    ///   - routineId: the session's routine (nil ⇒ every gate reads OFF; no-op).
    ///   - barWeight: active inventory bar (SC-plate-calculator BR-001).
    ///   - plateInventory: per-side plate denominations of the active inventory.
    public static func apply(
        db: Database,
        sessionId: String,
        routineId: String?,
        barWeight: Double,
        plateInventory: [Double]
    ) throws {
        guard let routineId else { return }   // BR-002: ad-hoc sessions never gate on

        // Distinct exercises in materialization order (first appearance).
        struct ExerciseSlice {
            var exerciseId: String
            var minSortOrder: Int
            var maxSortOrder: Int
            var maxPlannedWeight: Double?   // BR-001: W over work rows only
        }
        let slices = try Row.fetchAll(db, sql: """
            SELECT exerciseId,
                   MIN(sortOrder) AS minSort,
                   MAX(sortOrder) AS maxSort,
                   MAX(CASE WHEN setClass IS NULL OR setClass = 'work'
                            THEN plannedWeight END) AS W
            FROM completed_set
            WHERE sessionId = ? AND deletedAt IS NULL
            GROUP BY exerciseId
            ORDER BY MIN(sortOrder) ASC
            """, arguments: [sessionId]).map {
            ExerciseSlice(
                exerciseId: $0["exerciseId"],
                minSortOrder: $0["minSort"],
                maxSortOrder: $0["maxSort"],
                maxPlannedWeight: $0["W"]
            )
        }

        // Per-pair derivation with isolation: build the full plan first; any
        // single pair's bad state yields an empty ramp, not a thrown session.
        struct NewRow {
            var exerciseId: String
            var insertBase: Int      // = that exercise's original minSortOrder
            var rows: [WarmupRow]
        }
        var plan: [NewRow] = []

        var runningDelta = 0
        for (_, slice) in slices.enumerated() {
            // BR-009: snapshot immutability — never regenerate. A pair that already
            // carries generated warm-up rows in this session is left untouched, so a
            // caller-side double-apply is a no-op.
            let alreadyRamped = (try? Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM completed_set
                    WHERE sessionId = ? AND exerciseId = ?
                      AND setClass = 'warmup' AND deletedAt IS NULL
                    """, arguments: [sessionId, slice.exerciseId]) ?? 0) > 0
            guard !alreadyRamped else { continue }
            let enabled = (try? Int.fetchOne(db, sql: """
                    SELECT warmupEnabled FROM progression_scheme
                    WHERE routineId = ? AND exerciseId = ? AND deletedAt IS NULL
                    LIMIT 1
                    """, arguments: [routineId, slice.exerciseId]) ?? 0) == 1
            guard enabled else { continue }
            let rows = WarmupRamp.derive(
                workingWeight: slice.maxPlannedWeight,
                barWeight: barWeight,
                plateInventory: plateInventory
            )
            guard !rows.isEmpty else { continue }
            plan.append(NewRow(exerciseId: slice.exerciseId, insertBase: slice.minSortOrder, rows: rows))
            runningDelta += rows.count
        }
        guard !plan.isEmpty else { return }

        // Renumber + insert. SQLite has no ORDER BY on bare UPDATE, so do it
        // collision-free in three steps: park all rows at +totalOffset, insert the
        // derived rows into the vacated originals, then normalize the whole session
        // back to a contiguous 0..n-1 sequence (SC-foundation BR-005).
        let totalOffset = runningDelta
        try db.execute(sql: """
            UPDATE completed_set SET sortOrder = sortOrder + ?
            WHERE sessionId = ? AND deletedAt IS NULL
            """, arguments: [totalOffset, sessionId])

        let nowStr = ISO8601DateFormatter().string(from: Date())
        // Blocks sort ascending by insert position; each shift moves ALL rows
        // (any exercise) at/after the parked position so interleaved foreign rows
        // can't collide with an insertion, and later insertBases absorb prior
        // block sizes via `cumulative`.
        var cumulative = 0
        for entry in plan.sorted(by: { $0.insertBase < $1.insertBase }) {
            let position = entry.insertBase + totalOffset + cumulative
            let blockShift = entry.rows.count
            try db.execute(sql: """
                UPDATE completed_set SET sortOrder = sortOrder + ?, updatedAt = ?
                WHERE sessionId = ? AND sortOrder >= ? AND deletedAt IS NULL
                """, arguments: [blockShift, nowStr, sessionId, position])
            for (i, row) in entry.rows.enumerated() {
                try db.execute(sql: """
                    INSERT INTO completed_set
                        (id, sessionId, exerciseId, sortOrder,
                         plannedWeight, plannedReps, plannedDuration,
                         actualWeight, actualReps, actualDuration,
                         status, setClass, completedAt, createdAt, updatedAt, deletedAt)
                    VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, 'planned', 'warmup', NULL, ?, ?, NULL)
                    """, arguments: [
                        UUID().uuidString.lowercased(),
                        sessionId, entry.exerciseId, position + i,
                        row.weight, row.reps,
                        nowStr, nowStr,
                    ])
            }
            cumulative += blockShift
        }

        // Normalize: dense 0..n-1 by current order. SQLite cannot read a table
        // from inside an UPDATE on that same table, so fetch the parked order
        // and rewrite row-by-row (session sizes are small; O(n) writes).
        let parkedIds = try String.fetchAll(db, sql: """
            SELECT id FROM completed_set
            WHERE sessionId = ? AND deletedAt IS NULL
            ORDER BY sortOrder ASC
            """, arguments: [sessionId])
        for (i, id) in parkedIds.enumerated() {
            try db.execute(sql: """
                UPDATE completed_set SET sortOrder = ? WHERE id = ?
                """, arguments: [i, id])
        }
    }
}
