// contractId: SC-warmup @1.0.0
// Read-side persistence for the warm-up gate: ProgressionScheme.warmupEnabled
// per (routineId, exerciseId) pair (BR-002 / BR-010).
//
// Unlike ProgressionDAO.scheme(for:exerciseId:) this DAO NEVER auto-creates a
// scheme row: the gate default is OFF, so a missing row simply reads as false —
// materializing a session must not mint ProgressionScheme rows as a side effect.

import Foundation
import GRDB

public final class WarmupDAO {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    /// BR-002 gate input. Nil routineId (ad-hoc session) or absent/tombstoned
    /// scheme row ⇒ false (BR-010's zero-surprise default).
    public func warmupEnabled(routineId: String?, exerciseId: String) throws -> Bool {
        guard let routineId else { return false }
        return try dbQueue.read { db in
            let flag = try Int.fetchOne(db, sql: """
                SELECT warmupEnabled FROM progression_scheme
                WHERE routineId = ? AND exerciseId = ? AND deletedAt IS NULL
                LIMIT 1
                """, arguments: [routineId, exerciseId])
            return (flag ?? 0) == 1
        }
    }

    /// BR-015 helper for downstream work-class readers (PRs, progression, volume):
    /// does this exercise carry any 'warmup'-tagged row in the given session?
    /// When true, ambiguous unclassified custom rows in that same session must be
    /// excluded from work-class computation (mixed-history rule).
    public func sessionHasClassifiedWarmup(sessionId: String, exerciseId: String) throws -> Bool {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM completed_set
                WHERE sessionId = ? AND exerciseId = ?
                  AND setClass = 'warmup' AND deletedAt IS NULL
                """, arguments: [sessionId, exerciseId]) ?? 0 > 0
        }
    }
}
