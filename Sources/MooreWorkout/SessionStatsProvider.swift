// contractId: SC-workout-logging @1.0.0 (consumed seam) + SC-routines @1.0.0 §5
// The concrete `SessionStatsProviding` implementation (#22's session module
// supplies it — SC-routines' protocol doc). Reads only; no writes. The Home
// surface's per-routine derivations (lastUsedAt, last-session stats) and BR-005's
// streak feed come from `workout_session` + `completed_set` via these queries.
//
// Semantics pinned by Tests/MooreRoutinesTests/VerifyRoutines.mjs (the
// platform-free authority): a completed session is `endedAt IS NOT NULL`;
// last-used reads as MAX(endedAt) over this routine's completed sessions.

import Foundation
import GRDB
import MooreRoutines

private let statsISO = ISO8601DateFormatter()

public struct SessionStatsProvider: SessionStatsProviding, Sendable {
    public let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// The single in-flight session (`endedAt IS NULL`, live), if any — drives the
    /// Home quick-resume card and the mini-player bar. Sets are counted off
    /// `completed_set`: total live rows vs rows already `status = 'completed'`.
    public func activeSession() throws -> ActiveSessionSummary? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, routineId, startedAt
                FROM workout_session
                WHERE endedAt IS NULL AND deletedAt IS NULL
                ORDER BY startedAt DESC
                LIMIT 1
                """) else { return nil }

            let sessionId: String = row["id"]
            let routineId: String? = row["routineId"]
            let startedAtStr: String = row["startedAt"]

            // INV-3: the name resolves even for a tombstoned routine (no deletedAt filter).
            var routineName: String?
            if let rid = routineId {
                routineName = try String.fetchOne(db, sql: """
                    SELECT name FROM routine WHERE id = ?
                    """, arguments: [rid])
            }

            let setsTotal = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM completed_set
                WHERE sessionId = ? AND deletedAt IS NULL
                """, arguments: [sessionId]) ?? 0
            let setsDone = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM completed_set
                WHERE sessionId = ? AND status = 'completed' AND deletedAt IS NULL
                """, arguments: [sessionId]) ?? 0

            return ActiveSessionSummary(
                id: sessionId,
                routineId: routineId,
                routineName: routineName,
                startedAt: statsISO.date(from: startedAtStr) ?? Date(),
                setsDone: setsDone,
                setsTotal: setsTotal
            )
        }
    }

    /// Every completed session's `endedAt` — feeds BR-005's streak via
    /// StreakCalculator (SC-routines). Order irrelevant; tombstones excluded.
    public func completedSessionDates() throws -> [Date] {
        try dbQueue.read { db in
            let stamps = try String.fetchAll(db, sql: """
                SELECT endedAt FROM workout_session
                WHERE endedAt IS NOT NULL AND deletedAt IS NULL
                """)
            return stamps.compactMap { statsISO.date(from: $0) }
        }
    }

    /// The most recent completed session started from `routineId` (MAX endedAt),
    /// with its completed-set count and Σ(actualWeight × actualReps) over
    /// completed WORK sets only (SC-routines §3b `lastSessionVolumeKg`; warmup
    /// rows excluded per INV-6's coalesce — NULL setClass counts as work).
    public func lastCompletedSessionStats(routineId: String) throws -> SessionStats? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, endedAt
                FROM workout_session
                WHERE routineId = ? AND endedAt IS NOT NULL AND deletedAt IS NULL
                ORDER BY endedAt DESC, id DESC
                LIMIT 1
                """, arguments: [routineId]) else { return nil }

            let sessionId: String = row["id"]
            let endedAtStr: String = row["endedAt"]

            let setCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM completed_set
                WHERE sessionId = ? AND status = 'completed' AND deletedAt IS NULL
                """, arguments: [sessionId]) ?? 0

            let volumeKg = try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(actualWeight * actualReps), 0)
                FROM completed_set
                WHERE sessionId = ?
                  AND status = 'completed'
                  AND (setClass IS NULL OR setClass = 'work')
                  AND deletedAt IS NULL
                """, arguments: [sessionId]) ?? 0

            return SessionStats(
                completedAt: statsISO.date(from: endedAtStr) ?? Date(),
                setCount: setCount,
                volumeKg: volumeKg
            )
        }
    }
}
