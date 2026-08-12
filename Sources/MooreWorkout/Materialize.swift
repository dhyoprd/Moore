// contractId: SC-workout-logging @1.0.0
// Session materialisation (§5): routine PlannedSets → this session's CompletedSets.
// Per #3's dual-column invariant (SC-foundation INV-5): plannedX filled verbatim
// from the routine, actualX NULL, status 'planned', contiguous sortOrder preserved.
// One transaction. The caller (Home / Start CTA) supplies the routine's live sets —
// this file never reaches into MooreRoutines' storage internals.

import Foundation
import GRDB

public struct Materialize: Sendable {
    public let dao: WorkoutSessionDAO

    public init(dao: WorkoutSessionDAO) {
        self.dao = dao
    }

    /// One planned set as supplied by the caller (fetched from RoutineDAO).
    /// Shape mirrors SC-routines' `PlannedSet`, value-typed to avoid a module dep.
    public struct PlannedSetInput: Sendable {
        public var exerciseId: String
        public var plannedWeight: Double?
        public var plannedReps: Int?
        public var plannedDuration: Int?
        public var setClass: SetClass?

        public init(
            exerciseId: String,
            plannedWeight: Double? = nil,
            plannedReps: Int? = nil,
            plannedDuration: Int? = nil,
            setClass: SetClass? = nil
        ) {
            self.exerciseId = exerciseId
            self.plannedWeight = plannedWeight
            self.plannedReps = plannedReps
            self.plannedDuration = plannedDuration
            self.setClass = setClass
        }
    }

    /// Snapshot-copy a routine's planned sets into a fresh session (§2b materialise,
    /// SC-routines INV-R5: the copy is immutable once made — routine edits never
    /// drift into an open session). Returns the new session's id.
    @discardableResult
    public func startSession(
        routineId: String?,
        plannedSets: [PlannedSetInput],
        startDate: Date = Date()
    ) throws -> String {
        let now = Date()
        let nowStr = ISO8601DateFormatter().string(from: now)
        let sessionId = UUID().uuidString.lowercased()

        try dao.dbQueue.write { db in
            // Session row (0001 + 0003 + 0006 shape; ad-hoc when routineId nil).
            try db.execute(sql: """
                INSERT INTO workout_session
                    (id, routineId, name, notes, startedAt, endedAt,
                     importSource, importKey, createdAt, updatedAt, deletedAt)
                VALUES (?, ?, NULL, NULL, ?, NULL, NULL, NULL, ?, ?, NULL)
                """, arguments: [
                    sessionId, routineId,
                    ISO8601DateFormatter().string(from: startDate),
                    nowStr, nowStr,
                ])

            // Set rows — the load-bearing copy of the whole data model (#3).
            for (index, p) in plannedSets.enumerated() {
                try db.execute(sql: """
                    INSERT INTO completed_set
                        (id, sessionId, exerciseId, sortOrder,
                         plannedWeight, plannedReps, plannedDuration,
                         actualWeight, actualReps, actualDuration,
                         status, setClass, completedAt, createdAt, updatedAt, deletedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 'planned', ?, NULL, ?, ?, NULL)
                    """, arguments: [
                        UUID().uuidString.lowercased(),
                        sessionId, p.exerciseId, index,
                        p.plannedWeight, p.plannedReps, p.plannedDuration,
                        p.setClass?.rawValue,
                        nowStr, nowStr,
                    ])
            }
        }
        return sessionId
    }
}
