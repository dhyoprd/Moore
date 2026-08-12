// SC-foundation@1.0.0 — seam-2 typed DAO.
// Wraps GRDB's DatabasePool. Callers see typed methods per entity; no raw SQL
// strings leak outside `MigrationRunner` and the record-conformance extensions.
//
// Tombstone rule (BR-003): `softDelete*` flips `deletedAt`; `fetch*` filters by
// `deletedAt IS NULL` by default; `fetchIncludingTombstoned*` is the raw scan.

import Foundation
import GRDB

// MARK: - Table names + GRDB conformance

extension Folder: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "folder"
}
extension Exercise: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "exercise"
}
extension Routine: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "routine"
}
extension PlannedSet: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "planned_set"
}
extension WorkoutSession: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workout_session"
}
extension CompletedSet: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "completed_set"
}
extension PersonalRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "personal_record"
}
extension BodyMetric: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "body_metric"
}
extension ProgressionScheme: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "progression_scheme"
}

// MARK: - DAO

public struct Database {
    private let pool: DatabasePool

    public init(path: String) throws {
        pool = try DatabasePool(path: path)
        try MigrationRunner.migrate(pool)
    }

    public static func inMemory() throws -> Database {
        let pool = try DatabasePool()
        try MigrationRunner.migrate(pool)
        return Database(pool: pool)
    }

    private init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: Folder

    public func fetchFolders() throws -> [Folder] {
        try pool.read { db in
            try Folder.filter(Column("deletedAt") == nil).order(Column("name")).fetchAll(db)
        }
    }

    public func insertFolder(_ folder: Folder) throws {
        try pool.write { db in try folder.insert(db) }
    }

    public func softDeleteFolder(id: String, at now: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE folder SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }
    }

    // MARK: Exercise

    public func fetchExercises() throws -> [Exercise] {
        try pool.read { db in
            try Exercise.filter(Column("deletedAt") == nil).order(Column("name")).fetchAll(db)
        }
    }

    public func fetchExercise(id: String) throws -> Exercise? {
        try pool.read { db in
            try Exercise.filter(Column("id") == id && Column("deletedAt") == nil).fetchOne(db)
        }
    }

    public func insertExercise(_ exercise: Exercise) throws {
        try pool.write { db in try exercise.insert(db) }
    }

    public func softDeleteExercise(id: String, at now: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE exercise SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }
    }

    /// V14 escape hatch: raw scan including tombstones.
    public func fetchExercisesIncludingTombstoned() throws -> [Exercise] {
        try pool.read { db in try Exercise.fetchAll(db) }
    }

    public func fetchFoldersIncludingTombstoned() throws -> [Folder] {
        try pool.read { db in try Folder.fetchAll(db) }
    }

    // MARK: Routine

    public func fetchRoutines() throws -> [Routine] {
        try pool.read { db in
            try Routine.filter(Column("deletedAt") == nil)
                .order(Column("sortOrder"), Column("name"))
                .fetchAll(db)
        }
    }

    public func insertRoutine(_ routine: Routine) throws {
        try pool.write { db in try routine.insert(db) }
    }

    public func softDeleteRoutine(id: String, at now: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE routine SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }
    }

    // MARK: PlannedSet

    public func fetchPlannedSets(forRoutineId routineId: String) throws -> [PlannedSet] {
        try pool.read { db in
            try PlannedSet
                .filter(Column("routineId") == routineId && Column("deletedAt") == nil)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }

    public func insertPlannedSet(_ set: PlannedSet) throws {
        try pool.write { db in try set.insert(db) }
    }

    public func softDeletePlannedSet(id: String, at now: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE planned_set SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }
    }

    // MARK: WorkoutSession

    public func fetchWorkoutSessions() throws -> [WorkoutSession] {
        try pool.read { db in
            try WorkoutSession.filter(Column("deletedAt") == nil)
                .order(Column("startedAt").desc)
                .fetchAll(db)
        }
    }

    /// BR-007 dedupe check — returns the existing session id on conflict, nil on success.
    @discardableResult
    public func insertWorkoutSessionRespectingImportKey(_ session: WorkoutSession) throws -> String? {
        try pool.write { db in
            if let key = session.importKey {
                let dupe = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM workout_session WHERE importKey = ? AND deletedAt IS NULL",
                    arguments: [key]
                )
                if let dupe { return dupe }
            }
            try session.insert(db)
            return nil
        }
    }

    public func softDeleteWorkoutSession(id: String, at now: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE workout_session SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }
    }

    // MARK: CompletedSet

    public func fetchCompletedSets(forSessionId sessionId: String) throws -> [CompletedSet] {
        try pool.read { db in
            try CompletedSet
                .filter(Column("sessionId") == sessionId && Column("deletedAt") == nil)
                .order(Column("sortOrder"), Column("completedAt"))
                .fetchAll(db)
        }
    }

    /// #2's 1-tap accept — copy planned → actual, flip status to completed.
    public func completeSet(id: String, actualWeight: Double, actualReps: Int, completedAt now: String) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE completed_set
                       SET actualWeight = ?, actualReps = ?, status = 'completed',
                           completedAt = ?, updatedAt = ?
                     WHERE id = ?
                    """,
                arguments: [actualWeight, actualReps, now, now, id]
            )
        }
    }

    public func insertCompletedSet(_ set: CompletedSet) throws {
        try pool.write { db in try set.insert(db) }
    }

    public func softDeleteCompletedSet(id: String, at now: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE completed_set SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }
    }

    // MARK: PersonalRecord

    public func recordPR(_ pr: PersonalRecord) throws {
        try pool.write { db in try pr.insert(db) }
    }

    public func fetchPersonalRecords(forExerciseId exerciseId: String) throws -> [PersonalRecord] {
        try pool.read { db in
            try PersonalRecord
                .filter(Column("exerciseId") == exerciseId && Column("deletedAt") == nil)
                .order(Column("achievedAt").desc)
                .fetchAll(db)
        }
    }

    // MARK: BodyMetric

    public func recordBodyMetric(_ metric: BodyMetric) throws {
        try pool.write { db in try metric.insert(db) }
    }

    public func fetchBodyMetrics(kind: MetricKind) throws -> [BodyMetric] {
        try pool.read { db in
            try BodyMetric
                .filter(Column("kind") == kind.rawValue && Column("deletedAt") == nil)
                .order(Column("recordedAt").desc)
                .fetchAll(db)
        }
    }

    // MARK: ProgressionScheme

    public func fetchProgressionScheme(routineId: String, exerciseId: String) throws -> ProgressionScheme? {
        try pool.read { db in
            try ProgressionScheme
                .filter(
                    Column("routineId") == routineId
                        && Column("exerciseId") == exerciseId
                        && Column("deletedAt") == nil
                )
                .fetchOne(db)
        }
    }

    public func upsertProgressionScheme(_ scheme: ProgressionScheme) throws {
        try pool.write { db in try scheme.save(db) }
    }

    public func softDeleteProgressionScheme(id: String, at now: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE progression_scheme SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }
    }
}
