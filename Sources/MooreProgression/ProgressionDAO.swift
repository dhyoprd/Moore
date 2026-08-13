// GRDB-backed persistence for ProgressionScheme rows (SC-progression@1.0.0).
// Pure data access; engine math lives in ProgressionEngine.swift.

import Foundation
import GRDB

public struct ProgressionSchemeRow: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "progression_scheme"

    public var id: String
    public var routineId: String
    public var exerciseId: String
    public var scheme: String                     // none | linear | double | hold-duration
    public var incrementValue: Double?
    public var doubleProgressionMinReps: Int?
    public var doubleProgressionMaxReps: Int?
    public var warmupEnabled: Int
    public var stallCount: Int
    public var stallMuted: Int
    public var nextBannerAt: Int
    public var deloadPending: Int
    public var lastDeloadSessionId: String?
    public var stalledWeight: Double?
    public var stalledReps: Int?
    public var stalledDurationSec: Int?
    public var baselineDurationSec: Int?
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?

    public init(
        id: String, routineId: String, exerciseId: String,
        scheme: String = "none",
        incrementValue: Double? = nil,
        doubleProgressionMinReps: Int? = nil,
        doubleProgressionMaxReps: Int? = nil,
        warmupEnabled: Int = 0, stallCount: Int = 0, stallMuted: Int = 0,
        nextBannerAt: Int = 3, deloadPending: Int = 0,
        lastDeloadSessionId: String? = nil, stalledWeight: Double? = nil,
        stalledReps: Int? = nil, stalledDurationSec: Int? = nil, baselineDurationSec: Int? = nil,
        createdAt: String, updatedAt: String, deletedAt: String? = nil
    ) {
        self.id = id; self.routineId = routineId; self.exerciseId = exerciseId
        self.scheme = scheme; self.incrementValue = incrementValue
        self.doubleProgressionMinReps = doubleProgressionMinReps
        self.doubleProgressionMaxReps = doubleProgressionMaxReps
        self.warmupEnabled = warmupEnabled; self.stallCount = stallCount
        self.stallMuted = stallMuted; self.nextBannerAt = nextBannerAt
        self.deloadPending = deloadPending; self.lastDeloadSessionId = lastDeloadSessionId
        self.stalledWeight = stalledWeight; self.stalledReps = stalledReps
        self.stalledDurationSec = stalledDurationSec; self.baselineDurationSec = baselineDurationSec
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

// MARK: - DAO

public final class ProgressionDAO {
    let dbPool: DatabasePool

    public init(dbPool: DatabasePool) { self.dbPool = dbPool }

    /// BR-002 / BR-017 seam: fetch the scheme row for a (routineId, exerciseId)
    /// pair, auto-creating it at `none` if it doesn't exist (per #5's "auto-create
    /// if absent" in the pseudocode). Returned row is a snapshot; further mutations
    /// go through `save`.
    public func scheme(for routineId: String, exerciseId: String) throws -> ProgressionSchemeRow {
        try dbPool.read { db in
            if let row = try ProgressionSchemeRow
                .filter(Column("routineId") == routineId && Column("exerciseId") == exerciseId && Column("deletedAt") == nil)
                .fetchOne(db) {
                return row
            }
            /// Auto-provision at first consult (per BR-002 default=none).
            let created = ProgressionSchemeRow(
                id: UUID().uuidString, routineId: routineId, exerciseId: exerciseId,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
            return created
        }
    }

    /// #32 AC-3 seam (BR-009): resolve `exercise.category` FROM THE DATABASE for
    /// the engine's increment rule (legs/lower +5kg, upper +2.5kg, ambiguous
    /// upper-biased). The engine stays pure — callers pass this value into
    /// `ProgressionEngine.suggest` / `increment(forExerciseCategory:)`; nil
    /// (unclassified row or missing exercise) takes the upper-biased 2.5kg path.
    public func exerciseCategory(ofExercise exerciseId: String) throws -> String? {
        try dbPool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT category FROM exercise WHERE id = ?",
                arguments: [exerciseId]
            )
        }
    }

    public func save(_ row: ProgressionSchemeRow) throws {
        var copy = row
        copy.updatedAt = ISO8601DateFormatter().string(from: Date())
        try dbPool.write { db in
            try copy.save(db)
        }
    }

    /// Read the ≤5 newest completed sessions bearing this exercise, same routine
    /// preferred (BR-004). Returns rows ordered newest-first.
    public func referenceHistory(routineId: String, exerciseId: String, limit: Int = 5) throws -> [(sessionId: String, isSameRoutine: Bool, endedAt: String)] {
        try dbPool.read { db in
            let sql = """
                SELECT ws.id AS sessionId,
                       CASE WHEN ws.routineId = ? THEN 1 ELSE 0 END AS sameRoutine,
                       ws.endedAt AS endedAt
                FROM workout_session ws
                JOIN completed_set cs ON cs.sessionId = ws.id
                WHERE cs.exerciseId = ? AND ws.endedAt IS NOT NULL AND ws.deletedAt IS NULL
                GROUP BY ws.id
                ORDER BY sameRoutine DESC, ws.endedAt DESC
                LIMIT ?
                """
            return try Row.fetchAll(db, sql: sql, arguments: [routineId, exerciseId, limit]).map {
                (sessionId: $0["sessionId"], isSameRoutine: $0["sameRoutine"] == 1, endedAt: $0["endedAt"])
            }
        }
    }

    /// Load every completed_set row for a given exercise within a given session
    /// (BR-006/BR-007 evaluation feed).
    public func loadSets(sessionId: String, exerciseId: String) throws -> [ReferenceSessionSet] {
        try dbPool.read { db in
            let sql = """
                SELECT id, sessionId, exerciseId, sortOrder,
                       plannedWeight, plannedReps, plannedDuration,
                       actualWeight,  actualReps,  actualDuration,
                       status
                FROM completed_set
                WHERE sessionId = ? AND exerciseId = ? AND deletedAt IS NULL
                ORDER BY sortOrder ASC
                """
            return try Row.fetchAll(db, sql: sql, arguments: [sessionId, exerciseId]).map { row in
                ReferenceSessionSet(
                    sessionId: row["sessionId"],
                    routineId: nil,
                    status: SetStatus(rawValue: row["status"]) ?? .completed,
                    exerciseId: row["exerciseId"],
                    setOrdinal: row["sortOrder"],
                    plannedWeight: row["plannedWeight"],
                    plannedReps: row["plannedReps"],
                    plannedDuration: row["plannedDuration"],
                    actualWeight: row["actualWeight"],
                    actualReps: row["actualReps"],
                    actualDuration: row["actualDuration"]
                )
            }
        }
    }
}
