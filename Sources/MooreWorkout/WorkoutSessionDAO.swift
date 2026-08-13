// contractId: SC-workout-logging @1.0.0
// GRDB-backed DAO for `workout_session` + `completed_set` — the seam-2 persistence
// adapter the FSM drives (SC-workout-logging §5). Tombstone rule inherited from
// SC-foundation BR-003: deletes flip `deletedAt`; no `DELETE FROM` anywhere.

import Foundation
import GRDB

public enum WorkoutSessionError: Error, Equatable {
    case notFound(String)
    case alreadyFinished(String)
    case noSetsInSession(String)
}

// MARK: - Storage rows (GRDB record conformances)

/// Storage shape for `workout_session`
/// (0001 base + 0003's import columns + 0006's routineId).
struct WorkoutSessionRowStorage: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workout_session"
    var id: String
    var routineId: String?
    var name: String?
    var notes: String?
    var startedAt: String              // ISO-8601 UTC
    var endedAt: String?
    var importSource: String?
    var importKey: String?
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
}

/// Storage shape for `completed_set` (0001 shape + 0002's setClass column).
struct CompletedSetRowStorage: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "completed_set"
    var id: String
    var sessionId: String
    var exerciseId: String
    var sortOrder: Int
    var plannedWeight: Double?
    var plannedReps: Int?
    var plannedDuration: Int?
    var actualWeight: Double?
    var actualReps: Int?
    var actualDuration: Int?
    var status: String                 // CHECK constrained in 0001
    var setClass: String?
    var completedAt: String?
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
}

private let iso = ISO8601DateFormatter()

private func toSnapshot(_ r: CompletedSetRowStorage) -> SetSnapshot {
    SetSnapshot(
        id: r.id,
        exerciseId: r.exerciseId,
        sortOrder: r.sortOrder,
        status: SetStatus(rawValue: r.status) ?? .planned,
        plannedWeight: r.plannedWeight,
        plannedReps: r.plannedReps,
        plannedDurationSec: r.plannedDuration,
        actualWeight: r.actualWeight,
        actualReps: r.actualReps,
        actualDurationSec: r.actualDuration,
        setClass: r.setClass.flatMap { SetClass(rawValue: $0) },
        completedAt: r.completedAt.flatMap { iso.date(from: $0) }
    )
}

private func toStorage(_ s: SetSnapshot, sessionId: String, now: Date) -> CompletedSetRowStorage {
    let nowStr = iso.string(from: now)
    return CompletedSetRowStorage(
        id: s.id,
        sessionId: sessionId,
        exerciseId: s.exerciseId,
        sortOrder: s.sortOrder,
        plannedWeight: s.plannedWeight,
        plannedReps: s.plannedReps,
        plannedDuration: s.plannedDurationSec,
        actualWeight: s.actualWeight,
        actualReps: s.actualReps,
        actualDuration: s.actualDurationSec,
        status: s.status.rawValue,
        setClass: s.setClass?.rawValue,
        completedAt: s.completedAt.map { iso.string(from: $0) },
        createdAt: nowStr,
        updatedAt: nowStr,
        deletedAt: nil
    )
}

// MARK: - DAO

public struct WorkoutSessionDAO: Sendable {
    public let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: Materialise (§5 / SC-foundation INV-5)

    /// Insert the freshly-created `WorkoutSession` row. Set-row copying lives in
    /// `Materialize.swift` — it takes the routine's already-fetched planned sets so
    /// this DAO never crosses into MooreRoutines' storage internals.
    @discardableResult
    public func createSession(routineId: String?, at startDate: Date = Date()) throws -> WorkoutSessionRowStorage {
        let nowStr = iso.string(from: Date())
        let sessionId = UUID().uuidString.lowercased()
        let session = WorkoutSessionRowStorage(
            id: sessionId,
            routineId: routineId,
            name: nil, notes: nil,
            startedAt: iso.string(from: startDate), endedAt: nil,
            importSource: nil, importKey: nil,
            createdAt: nowStr, updatedAt: nowStr, deletedAt: nil
        )
        try dbQueue.write { db in
            try session.insert(db)
        }
        return session
    }

    /// Insert one materialised set row (plannedX verbatim, actualX NULL,
    /// `status = 'planned'`). Used by `Materialize.swift` inside its transaction.
    public func insertMaterializedSet(_ row: CompletedSetRowStorage, db: Database) throws {
        try row.insert(db)
    }

    // MARK: Read

    /// Rebuild the FSM's in-memory snapshot from SQLite (§5's cold-render seam:
    /// state recomputed from rows, never from a daemon — #9 rule 4).
    public func fetchSessionState(sessionId: String) throws -> WorkoutSessionFSM {
        try dbQueue.read { db in
            guard try WorkoutSessionRowStorage.fetchOne(db, key: sessionId) != nil else {
                throw WorkoutSessionError.notFound(sessionId)
            }
            let rows = try CompletedSetRowStorage
                .filter(Column("sessionId") == sessionId && Column("deletedAt") == nil)
                .order(Column("sortOrder"))
                .fetchAll(db)
            return WorkoutSessionFSM(sessionId: sessionId, sets: rows.map(toSnapshot))
        }
    }

    /// The exercise's most recent row in this session — the template for `[+]`'s
    /// add-set pre-fill (BR-004).
    public func fetchLastExerciseRow(sessionId: String, exerciseId: String) throws -> SetSnapshot? {
        try dbQueue.read { db in
            try CompletedSetRowStorage
                .filter(
                    Column("sessionId") == sessionId
                        && Column("exerciseId") == exerciseId
                        && Column("deletedAt") == nil
                )
                .order(Column("sortOrder").desc)
                .fetchOne(db)
        }
        .map(toSnapshot)
    }

    /// All live sets for a session, sorted (FSM snapshot reconstruction helper).
    public func fetchSets(sessionId: String) throws -> [SetSnapshot] {
        try dbQueue.read { db in
            try CompletedSetRowStorage
                .filter(Column("sessionId") == sessionId && Column("deletedAt") == nil)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
        .map(toSnapshot)
    }

    // MARK: Write — set status flip (the FSM's persistence adapter, §5)

    /// Persist a set's transition: status + actuals + `completedAt` stamp, bump
    /// `updatedAt` (INV-2). Called by the FSM's adapter after a lawful dispatch;
    /// never invoked directly from the UI (no write path around the FSM).
    public func updateSetStatus(
        setId: String,
        status: SetStatus,
        actualWeight: Double?,
        actualReps: Int?,
        actualDuration: Int?,
        completedAt: Date? = nil
    ) throws {
        let nowStr = iso.string(from: Date())
        try dbQueue.write { db in
            guard var row = try CompletedSetRowStorage.fetchOne(db, key: setId),
                  row.deletedAt == nil else {
                throw WorkoutSessionError.notFound(setId)
            }
            row.status = status.rawValue
            row.actualWeight = actualWeight
            row.actualReps = actualReps
            row.actualDuration = actualDuration
            if status != .planned, let completedAt {
                row.completedAt = iso.string(from: completedAt)
            }
            row.updatedAt = nowStr
            try row.update(db)
        }
    }

    /// Persist `undoDrop` (BR-003): re-open a dropped row to `planned` with NULL
    /// actuals and NULL `completedAt` — the undo restores the pre-drop row shape
    /// (§2a: `dropped → planned` while the window is open; JS mirror of the
    /// contract verifier writes exactly these columns). Bumps `updatedAt` (INV-2).
    public func undoDropSet(setId: String) throws {
        let nowStr = iso.string(from: Date())
        try dbQueue.write { db in
            guard var row = try CompletedSetRowStorage.fetchOne(db, key: setId),
                  row.deletedAt == nil else {
                throw WorkoutSessionError.notFound(setId)
            }
            row.status = SetStatus.planned.rawValue
            row.actualWeight = nil
            row.actualReps = nil
            row.actualDuration = nil
            row.completedAt = nil
            row.updatedAt = nowStr
            try row.update(db)
        }
    }

    /// Append a new pre-filled row (BR-004). Returns the new set's id.
    @discardableResult
    public func appendSet(
        sessionId: String,
        exerciseId: String,
        plannedWeight: Double?,
        plannedReps: Int?,
        plannedDuration: Int?,
        setClass: SetClass?
    ) throws -> String {
        let now = Date()
        let nowStr = iso.string(from: now)
        return try dbQueue.write { db in
            let nextOrder = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(sortOrder) + 1, 0) FROM completed_set
                WHERE sessionId = ? AND deletedAt IS NULL
                """, arguments: [sessionId]) ?? 0
            let id = UUID().uuidString.lowercased()
            let row = CompletedSetRowStorage(
                id: id,
                sessionId: sessionId,
                exerciseId: exerciseId,
                sortOrder: nextOrder,
                plannedWeight: plannedWeight,
                plannedReps: plannedReps,
                plannedDuration: plannedDuration,
                actualWeight: nil, actualReps: nil, actualDuration: nil,
                status: SetStatus.planned.rawValue,
                setClass: setClass?.rawValue,
                completedAt: nil,
                createdAt: nowStr, updatedAt: nowStr, deletedAt: nil
            )
            try row.insert(db)
            return id
        }
    }

    // MARK: Finish (BR-008 / INV-W8)

    /// Stamp `endedAt` exactly once. Idempotent: re-finishing an already-finished
    /// session throws (INV-W8: `endedAt` written exactly once).
    public func finishSession(sessionId: String, at date: Date) throws {
        let nowStr = iso.string(from: Date())
        try dbQueue.write { db in
            guard var row = try WorkoutSessionRowStorage.fetchOne(db, key: sessionId),
                  row.deletedAt == nil else {
                throw WorkoutSessionError.notFound(sessionId)
            }
            guard row.endedAt == nil else {
                throw WorkoutSessionError.alreadyFinished(sessionId)
            }
            row.endedAt = iso.string(from: date)
            row.updatedAt = nowStr
            try row.update(db)
        }
    }
}
