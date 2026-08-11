// contractId: SC-routines @1.0.0
// GRDB-backed DAO for `routine` + `planned_set`. Typed methods replace raw SQL for
// callers; only this file (and FolderDAO) import GRDB in MooreRoutines.
// Tombstone rule (BR-003 / SC-foundation BR-003): deletes flip `deletedAt`; reads
// filter `deletedAt IS NULL` by default. No `DELETE FROM` anywhere at this layer.

import Foundation
import GRDB

public enum RoutineError: Error, Equatable {
    case notFound(String)
    case duplicateOfTombstoned(String)   // reserved; duplicate never errors today
}

// MARK: - Storage rows (GRDB record conformances)

/// Storage shape for `routine` (created by #19's 0001; guarded by 0005).
struct RoutineRowStorage: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "routine"
    var id: String
    var folderId: String?
    var name: String
    var sortOrder: Int
    var createdAt: String              // ISO-8601 UTC
    var updatedAt: String
    var deletedAt: String?
}

/// Storage shape for `planned_set` (0001 shape + 0002's setClass column).
struct PlannedSetRowStorage: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "planned_set"
    var id: String
    var routineId: String
    var exerciseId: String
    var sortOrder: Int
    var plannedWeight: Double?
    var plannedReps: Int?
    var plannedDuration: Int?
    var setClass: String?              // 'warmup' | 'work' | NULL (pre-0002)
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
}

private let iso = ISO8601DateFormatter()

private func toDomain(_ r: RoutineRowStorage) -> Routine {
    Routine(
        id: r.id,
        folderId: r.folderId,
        name: r.name,
        sortOrder: r.sortOrder,
        createdAt: iso.date(from: r.createdAt) ?? Date.distantPast,
        updatedAt: iso.date(from: r.updatedAt) ?? Date.distantPast,
        deletedAt: r.deletedAt.flatMap { iso.date(from: $0) }
    )
}

private func toDomain(_ p: PlannedSetRowStorage) -> PlannedSet {
    PlannedSet(
        id: p.id,
        routineId: p.routineId,
        exerciseId: p.exerciseId,
        sortOrder: p.sortOrder,
        plannedWeight: p.plannedWeight,
        plannedReps: p.plannedReps,
        plannedDuration: p.plannedDuration,
        setClass: p.setClass.flatMap { SetClass(rawValue: $0) },
        createdAt: iso.date(from: p.createdAt) ?? Date.distantPast,
        updatedAt: iso.date(from: p.updatedAt) ?? Date.distantPast,
        deletedAt: p.deletedAt.flatMap { iso.date(from: $0) }
    )
}

private func toStorage(_ p: PlannedSet) -> PlannedSetRowStorage {
    PlannedSetRowStorage(
        id: p.id,
        routineId: p.routineId,
        exerciseId: p.exerciseId,
        sortOrder: p.sortOrder,
        plannedWeight: p.plannedWeight,
        plannedReps: p.plannedReps,
        plannedDuration: p.plannedDuration,
        setClass: p.setClass?.rawValue,
        createdAt: iso.string(from: p.createdAt),
        updatedAt: iso.string(from: p.updatedAt),
        deletedAt: p.deletedAt.map { iso.string(from: $0) }
    )
}

// MARK: - DAO

public struct RoutineDAO: Sendable {
    public let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: Create (V1)

    /// Creates a routine with its planned sets in one transaction. `exerciseList` is
    /// the editor's flat set list (order = sortOrder, 0-based). Legal with an empty
    /// list (§2a draft); such a routine has `startEnabled = false` (BR-001).
    @discardableResult
    public func create(
        name: String,
        folderId: String? = nil,
        exerciseList: [EditableSetDraft]
    ) throws -> Routine {
        let now = Date()
        let routine = Routine(
            id: UUID().uuidString.lowercased(),
            folderId: folderId,
            name: name,
            sortOrder: 0,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )
        try dbQueue.write { db in
            try RoutineRowStorage(
                id: routine.id, folderId: routine.folderId, name: routine.name,
                sortOrder: routine.sortOrder,
                createdAt: iso.string(from: now), updatedAt: iso.string(from: now),
                deletedAt: nil
            ).insert(db)
            for (index, draft) in exerciseList.enumerated() {
                let set = PlannedSet(
                    id: draft.id.isEmpty ? UUID().uuidString.lowercased() : draft.id,
                    routineId: routine.id,
                    exerciseId: draft.exerciseId,
                    sortOrder: index,
                    plannedWeight: draft.plannedWeight,
                    plannedReps: draft.plannedReps,
                    plannedDuration: draft.plannedDuration,
                    setClass: draft.setClass,
                    createdAt: now, updatedAt: now, deletedAt: nil
                )
                try toStorage(set).insert(db)
            }
        }
        return routine
    }

    // MARK: Read

    /// Live (non-tombstoned) routines only — the Home surface source list.
    public func fetchAll() throws -> [Routine] {
        try dbQueue.read { db in
            try RoutineRowStorage
                .filter(Column("deletedAt") == nil)
                .order(Column("name"))
                .fetchAll(db)
        }
        .map(toDomain)
    }

    /// Single live routine by id; nil when absent or tombstoned.
    public func fetch(id: String) throws -> Routine? {
        try dbQueue.read { db in
            try RoutineRowStorage
                .filter(Column("id") == id && Column("deletedAt") == nil)
                .fetchOne(db)
        }
        .map(toDomain)
    }

    /// Raw fetch incl. tombstoned (INV-3: history must resolve names).
    public func fetchIncludingTombstoned(id: String) throws -> Routine? {
        try dbQueue.read { db in
            try RoutineRowStorage.fetchOne(db, key: id)
        }
        .map(toDomain)
    }

    /// Live planned sets for a routine, ordered for the editor and for materialisation.
    public func fetchSets(routineId: String) throws -> [PlannedSet] {
        try dbQueue.read { db in
            try PlannedSetRowStorage
                .filter(Column("routineId") == routineId && Column("deletedAt") == nil)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
        .map(toDomain)
    }

    /// Distinct live exercise ids in a routine — drives `exerciseCount` / BR-001.
    public func exerciseCount(routineId: String) throws -> Int {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT exerciseId FROM planned_set
                WHERE routineId = ? AND deletedAt IS NULL
                """, arguments: [routineId])
            return rows.count
        }
    }

    // MARK: Update (V2 — reorder / add / remove / change planned values)

    /// Applies an editor buffer's set list to a routine. Reorders via fresh sortOrder,
    /// inserts new sets, updates existing planned values, tombstones removed sets —
    /// all in one transaction; bumps the routine's `updatedAt` (INV-2), `createdAt` intact.
    @discardableResult
    public func update(
        id: String,
        name: String?,
        folderId: String?? = nil,      // double-optional: nil = leave, .some(nil) = unfile
        setDrafts: [EditableSetDraft]
    ) throws -> Routine {
        let now = Date()
        let nowStr = iso.string(from: now)
        return try dbQueue.write { db in
            guard var row = try RoutineRowStorage.fetchOne(db, key: id),
                  row.deletedAt == nil else {
                throw RoutineError.notFound(id)
            }
            if let name { row.name = name }
            if let folderId { row.folderId = folderId }   // .some(nil) unfiles
            row.updatedAt = nowStr
            try row.update(db)

            // Existing live sets, keyed by id.
            let existing = try PlannedSetRowStorage
                .filter(Column("routineId") == id && Column("deletedAt") == nil)
                .fetchAll(db)
            let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let keptIds = Set(setDrafts.map { $0.id })

            // Tombstone removed sets (BR-003 — no hard delete).
            for old in existing where !keptIds.contains(old.id) {
                var dead = old
                dead.deletedAt = nowStr
                dead.updatedAt = nowStr
                try dead.update(db)
            }
            // Upsert the remaining/new drafts in order.
            for (index, draft) in setDrafts.enumerated() {
                if var cur = existingById[draft.id] {
                    cur.sortOrder = index
                    cur.exerciseId = draft.exerciseId
                    cur.plannedWeight = draft.plannedWeight
                    cur.plannedReps = draft.plannedReps
                    cur.plannedDuration = draft.plannedDuration
                    cur.setClass = draft.setClass.rawValue
                    cur.updatedAt = nowStr
                    try cur.update(db)
                } else {
                    let set = PlannedSet(
                        id: draft.id,
                        routineId: id,
                        exerciseId: draft.exerciseId,
                        sortOrder: index,
                        plannedWeight: draft.plannedWeight,
                        plannedReps: draft.plannedReps,
                        plannedDuration: draft.plannedDuration,
                        setClass: draft.setClass,
                        createdAt: now, updatedAt: now, deletedAt: nil
                    )
                    try toStorage(set).insert(db)
                }
            }
            return toDomain(row)
        }
    }

    // MARK: Duplicate (BR-002 / V3)

    /// Deep copy: new routine UUID, `name = "Copy of " + source`, same `folderId`,
    /// every live PlannedSet copied with a new id (same sortOrder/exerciseId/plannedX/
    /// setClass), all in one transaction. The copy enters lifecycle as `draft`.
    @discardableResult
    public func duplicate(sourceId: String) throws -> Routine {
        let now = Date()
        let nowStr = iso.string(from: now)
        return try dbQueue.write { db in
            guard let src = try RoutineRowStorage.fetchOne(db, key: sourceId),
                  src.deletedAt == nil else {
                throw RoutineError.notFound(sourceId)
            }
            let copy = Routine(
                id: UUID().uuidString.lowercased(),
                folderId: src.folderId,
                name: "Copy of " + src.name,
                sortOrder: src.sortOrder,
                createdAt: now, updatedAt: now, deletedAt: nil
            )
            try RoutineRowStorage(
                id: copy.id, folderId: copy.folderId, name: copy.name,
                sortOrder: copy.sortOrder, createdAt: nowStr, updatedAt: nowStr, deletedAt: nil
            ).insert(db)

            let srcSets = try PlannedSetRowStorage
                .filter(Column("routineId") == sourceId && Column("deletedAt") == nil)
                .fetchAll(db)
            for s in srcSets {
                var newSet = s
                newSet.id = UUID().uuidString.lowercased()
                newSet.routineId = copy.id
                newSet.createdAt = nowStr
                newSet.updatedAt = nowStr
                newSet.deletedAt = nil
                try newSet.insert(db)
            }
            return copy
        }
    }

    // MARK: Delete (BR-004 / V4 — confirm-first is a UI concern; the write is a tombstone)

    /// Soft-deletes a routine (INV-3). Idempotent. Planned sets remain (they are the
    /// routine's snapshot record); the routine simply leaves every default fetch.
    public func tombstone(id: String) throws {
        let nowStr = iso.string(from: Date())
        try dbQueue.write { db in
            guard var row = try RoutineRowStorage.fetchOne(db, key: id) else {
                throw RoutineError.notFound(id)
            }
            guard row.deletedAt == nil else { return }
            row.deletedAt = nowStr
            row.updatedAt = nowStr
            try row.update(db)
        }
    }

    /// Move a routine into a folder, or unfile it (`folderId = nil`). Cosmetic (INV-R3).
    public func moveToFolder(routineId: String, folderId: String?) throws {
        let nowStr = iso.string(from: Date())
        try dbQueue.write { db in
            guard var row = try RoutineRowStorage.fetchOne(db, key: routineId),
                  row.deletedAt == nil else {
                throw RoutineError.notFound(routineId)
            }
            row.folderId = folderId
            row.updatedAt = nowStr
            try row.update(db)
        }
    }
}
