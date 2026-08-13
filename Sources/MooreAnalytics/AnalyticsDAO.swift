// contractId: SC-analytics @1.0.0
// §5 seam-2 DAO: GRDB read-only queries (INV-A1 — analytics never persisted).
// Every method is a `dbQueue.read`; there is no write path in this module. All
// aggregation happens in AnalyticsEngine over these row reads, so the SQL stays
// trivial SELECTs and the math stays seam-1 testable / port-identical.

import Foundation
import GRDB

public struct AnalyticsDAO: Sendable {
    public let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Raw reads (INV-A2 tombstone discipline)

    /// Live sessions only (INV-3).
    public func fetchSessions() throws -> [AnalyticsSession] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name, startedAt, endedAt
                  FROM workout_session
                 WHERE deletedAt IS NULL
                 ORDER BY startedAt ASC
                """).map { row in
                    AnalyticsSession(
                        id: row["id"],
                        name: row["name"],
                        startedAt: row["startedAt"],
                        endedAt: row["endedAt"]
                    )
                }
        }
    }

    /// Live sets only (INV-3); planned/actual dual columns intact (INV-5).
    public func fetchSets() throws -> [AnalyticsSet] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, sessionId, exerciseId, sortOrder,
                       plannedWeight, plannedReps, plannedDuration,
                       actualWeight, actualReps, actualDuration,
                       status, setClass, completedAt
                  FROM completed_set
                 WHERE deletedAt IS NULL
                 ORDER BY sessionId, sortOrder ASC
                """).map { row in
                    AnalyticsSet(
                        id: row["id"],
                        sessionId: row["sessionId"],
                        exerciseId: row["exerciseId"],
                        sortOrder: row["sortOrder"],
                        plannedWeight: row["plannedWeight"],
                        plannedReps: row["plannedReps"],
                        plannedDuration: row["plannedDuration"],
                        actualWeight: row["actualWeight"],
                        actualReps: row["actualReps"],
                        actualDuration: row["actualDuration"],
                        status: row["status"],
                        setClass: row["setClass"],
                        completedAt: row["completedAt"]
                    )
                }
        }
    }

    /// Exercises including tombstoned rows: analytics must still name and bucket
    /// historic volume for hidden/deleted exercises (SC-exercises INV-L3).
    public func fetchExercises() throws -> [ExerciseInfo] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name, category FROM exercise ORDER BY id
                """).map { row in
                    ExerciseInfo(id: row["id"], name: row["name"], category: row["category"])
                }
        }
    }

    /// Live personal_record rows, post-0009 shape (SC-prs §3a).
    public func fetchPRRows() throws -> [PRRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, exerciseId, sessionId, kind, value, achievedAt
                  FROM personal_record
                 WHERE deletedAt IS NULL
                 ORDER BY achievedAt DESC
                """).map { row in
                    PRRow(
                        id: row["id"],
                        exerciseId: row["exerciseId"],
                        sessionId: row["sessionId"],
                        kind: row["kind"],
                        value: row["value"],
                        achievedAt: row["achievedAt"]
                    )
                }
        }
    }

    // MARK: - Composed reads (all engine math, all read-only)

    /// Streak/adherence header (BR-001/BR-010).
    public func adherenceHeader(today: String) throws -> AdherenceHeader {
        let sessions = try fetchSessions()
        let sets = try fetchSets()
        return AnalyticsEngine.adherenceHeader(sessions: sessions, sets: sets, today: today)
    }

    /// Per-exercise Epley 1RM trend (BR-002).
    public func epleyTrend(exerciseId: String, today: String, rangeDays: Int) throws -> [TrendPoint] {
        let sessions = try fetchSessions()
        let sets = try fetchSets()
        return AnalyticsEngine.epleyTrend(
            sessions: sessions, sets: sets, exerciseId: exerciseId,
            today: today, rangeDays: rangeDays
        )
    }

    /// Weekly tonnage, warmups excluded (BR-003).
    public func weeklyTonnage(today: String, rangeDays: Int) throws -> [WeekTonnage] {
        let sessions = try fetchSessions()
        let sets = try fetchSets()
        return AnalyticsEngine.weeklyTonnage(sessions: sessions, sets: sets, today: today, rangeDays: rangeDays)
    }

    /// Muscle split across category buckets (BR-004).
    public func muscleSplit(today: String, rangeDays: Int) throws -> [MuscleBucket] {
        let sessions = try fetchSessions()
        let sets = try fetchSets()
        let exercises = try fetchExercises()
        return AnalyticsEngine.muscleSplit(
            sessions: sessions, sets: sets, exercises: exercises,
            today: today, rangeDays: rangeDays
        )
    }

    /// PR list, reverse-chronological (BR-005).
    public func prList() throws -> [PRListItem] {
        let rows = try fetchPRRows()
        let exercises = try fetchExercises()
        return AnalyticsEngine.prList(rows: rows, exercises: exercises)
    }

    /// Month-grouped History with PR badge counts (BR-006). The badge probe rides
    /// SC-prs' `personal_record_session_idx` (SELECT-only, per-session count).
    public func history() throws -> [HistoryMonth] {
        let sessions = try fetchSessions()
        let sets = try fetchSets()
        let prs = try fetchPRRows()
        return AnalyticsEngine.history(sessions: sessions, sets: sets, prs: prs)
    }

    /// Session detail: plan-vs-actual rows (BR-007) + the exercise's unwindowed
    /// e1RM sparkline (BR-002 with a full-history window).
    public func sessionDetail(sessionId: String, today: String) throws -> (rows: [PlanActualRow], sparkline: [TrendPoint]) {
        let sessions = try fetchSessions()
        let sets = try fetchSets()
        let rows = AnalyticsEngine.sessionDetailRows(sessionId: sessionId, sets: sets)
        // Sparkline over full history: a window large enough to hold any real log.
        let exerciseId = rows.first?.exerciseId
        let sparkline: [TrendPoint]
        if let exerciseId {
            sparkline = AnalyticsEngine.epleyTrend(
                sessions: sessions, sets: sets, exerciseId: exerciseId,
                today: today, rangeDays: 36500
            )
        } else {
            sparkline = []
        }
        return (rows, sparkline)
    }
}
