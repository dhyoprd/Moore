// contractId: SC-exercises @1.0.0
// GRDB-backed DAO for the `exercise` table.
// This is the ONLY file in MooreExercises allowed to import GRDB. All other layers
// see plain `Exercise` structs. Typed methods replace raw SQL for callers.

import Foundation
import GRDB

/// Storage-backed exercise row, mapped from GRDB. Mirrors `Exercise` in Models.swift.
public struct ExerciseRow: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "exercise"

    public var id: String
    public var name: String
    public var nameNormalized: String
    public var category: String
    public var defaultMetric: String
    public var equipment: String
    public var isCustom: Int
    public var defaultRestSec: Int?
    public var createdAt: String   // ISO-8601 UTC
    public var updatedAt: String
    public var deletedAt: String?

    public func toDomain() throws -> Exercise {
        guard
            let cat = ExerciseCategory(rawValue: category),
            let met = DefaultMetric(rawValue: defaultMetric),
            let eqp = ExerciseEquipment(rawValue: equipment)
        else {
            throw ExerciseLibraryError.malformedSeed("row \(id) has out-of-enum category/metric/equipment")
        }
        let fmt = ISO8601DateFormatter()
        guard let created = fmt.date(from: createdAt), let updated = fmt.date(from: updatedAt) else {
            throw ExerciseLibraryError.malformedSeed("row \(id) has unparseable timestamps")
        }
        return Exercise(
            id: id,
            isCustom: isCustom == 1,
            name: name,
            nameNormalized: nameNormalized,
            category: cat,
            defaultMetric: met,
            equipment: eqp,
            defaultRestSec: defaultRestSec,
            createdAt: created,
            updatedAt: updated,
            deletedAt: deletedAt.flatMap { fmt.date(from: $0) }
        )
    }

    public init(domain: Exercise) {
        let fmt = ISO8601DateFormatter()
        self.id = domain.id
        self.name = domain.name
        self.nameNormalized = domain.nameNormalized
        self.category = domain.category.rawValue
        self.defaultMetric = domain.defaultMetric.rawValue
        self.equipment = domain.equipment.rawValue
        self.isCustom = domain.isCustom ? 1 : 0
        self.defaultRestSec = domain.defaultRestSec
        self.createdAt = fmt.string(from: domain.createdAt)
        self.updatedAt = fmt.string(from: domain.updatedAt)
        self.deletedAt = domain.deletedAt.map { fmt.string(from: $0) }
    }

    public init(
        id: String,
        name: String,
        nameNormalized: String,
        category: String,
        defaultMetric: String,
        equipment: String,
        isCustom: Int,
        defaultRestSec: Int?,
        createdAt: String,
        updatedAt: String,
        deletedAt: String?
    ) {
        self.id = id
        self.name = name
        self.nameNormalized = nameNormalized
        self.category = category
        self.defaultMetric = defaultMetric
        self.equipment = equipment
        self.isCustom = isCustom
        self.defaultRestSec = defaultRestSec
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public enum CreateCustomResult: Equatable, Sendable {
    case inserted(Exercise)
    case matchedExisting(Exercise)      // BR-005(a)
    case restoredCustom(Exercise)       // BR-005(b)
    case restoredBuiltIn(Exercise)      // BR-005(c)
}

/// The DAO. All mutations run inside the caller's transaction; built-in rows refuse
/// field mutations at this layer (BR-002).
public struct ExerciseDAO: Sendable {
    public let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Seeding (BR-006)

    /// Idempotent: runs every launch. INSERT OR IGNORE per seed row; conflicts leave
    /// existing rows untouched (they keep their own createdAt/updatedAt).
    public func seedBuiltInsIfNeeded(seedURL: URL) throws {
        let jsonData = try Data(contentsOf: seedURL)
        let seed = try ExerciseLibrary.decodeBuiltinSeed(jsonData: jsonData)
        let now = Date()
        try dbQueue.write { db in
            for entry in seed.exercises {
                let row = ExerciseLibrary.row(from: entry, createdAt: now, updatedAt: now)
                let storage = ExerciseRow(domain: row)
                try storage.insert(db, onConflict: .ignore)
            }
        }
    }

    // MARK: - Reads

    /// BR-003: substring against `name_normalized`, tombstoneds excluded. Caller
    /// supplies the normalized query string (application of BR-001 is caller's
    /// responsibility — see `searchNamed`).
    public func searchNamed(
        _ query: String,
        category: ExerciseCategory? = nil,
        excludeIds: Set<String> = []
    ) throws -> [Exercise] {
        let normalized = NameNormalization.normalize(query)
        let rows: [ExerciseRow] = try dbQueue.read { db in
            var sql = "SELECT * FROM exercise WHERE deleted_at IS NULL"
            var args: [Any] = []
            if !excludeIds.isEmpty {
                let placeholders = excludeIds.map { _ in "?" }.joined(separator: ",")
                sql += " AND id NOT IN (\(placeholders))"
                args.append(contentsOf: excludeIds.map { $0 as Any })
            }
            if let category {
                sql += " AND category = ?"
                args.append(category.rawValue)
            }
            if !normalized.isEmpty {
                sql += " AND name_normalized LIKE ?"
                args.append("%\(normalized)%")
            }
            sql += " ORDER BY name ASC"
            return try ExerciseRow
                .fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
        var domainRows = try rows.map { try $0.toDomain() }
        if !normalized.isEmpty {
            // exact hit first, then built-ins, then alphabetical
            domainRows.sort { a, b in
                let aExact = a.nameNormalized == normalized
                let bExact = b.nameNormalized == normalized
                if aExact != bExact { return aExact }
                if a.isCustom != b.isCustom { return !a.isCustom }
                return a.name < b.name
            }
        }
        return domainRows
    }

    /// INV-L3: fetch by id returns the row regardless of tombstone state. Historic
    /// CompletedSets must resolve names through this method.
    public func getById(_ id: String) throws -> Exercise? {
        let row: ExerciseRow? = try dbQueue.read { db in
            try ExerciseRow.fetchOne(db, key: id)
        }
        return try row?.toDomain()
    }

    /// BR-001 lookup for dedupe: includes tombstoned rows (needed for BR-005's
    /// restore branches).
    public func findByNormalizedName(_ name: String) throws -> Exercise? {
        let normalized = NameNormalization.normalize(name)
        let rows: [ExerciseRow] = try dbQueue.read { db in
            try ExerciseRow
                .filter(Column("name_normalized") == normalized)
                .fetchAll(db)
        }
        return try rows.map { try $0.toDomain() }.first
    }

    // MARK: - Writes

    /// BR-005 create-custom: inserts, matches existing, or restores tombstoned —
    /// all inside a single database transaction.
    public func insertCustom(
        name rawName: String,
        category: ExerciseCategory,
        defaultMetric: DefaultMetric,
        equipment: ExerciseEquipment,
        defaultRestSec: Int? = nil
    ) throws -> CreateCustomResult {
        let displayName = NameNormalization.displayForm(rawName)
        let normalized = NameNormalization.normalize(rawName)
        let now = Date()
        let fmt = ISO8601DateFormatter()
        return try dbQueue.write { db -> CreateCustomResult in
            // (a) non-tombstoned row sharing the normalized name?
            if let existing = try ExerciseRow
                .filter(Column("name_normalized") == normalized && Column("deleted_at") == nil)
                .fetchOne(db) {
                return .matchedExisting(try existing.toDomain())
            }
            // (b)/(c) tombstoned row sharing the normalized name?
            if let tombstoned = try ExerciseRow
                .filter(Column("name_normalized") == normalized && Column("deleted_at") != nil)
                .fetchOne(db) {
                var r = tombstoned
                r.deletedAt = nil
                r.updatedAt = fmt.string(from: now)
                try r.update(db)
                let restored = try r.toDomain()
                return restored.isCustom ? .restoredCustom(restored) : .restoredBuiltIn(restored)
            }
            // (d) brand new
            let newRow = ExerciseRow(
                id: UUID().uuidString.lowercased(),
                name: displayName,
                nameNormalized: normalized,
                category: category.rawValue,
                defaultMetric: defaultMetric.rawValue,
                equipment: equipment.rawValue,
                isCustom: 1,
                defaultRestSec: defaultRestSec,
                createdAt: fmt.string(from: now),
                updatedAt: fmt.string(from: now),
                deletedAt: nil
            )
            try newRow.insert(db)
            return .inserted(try newRow.toDomain())
        }
    }

    /// INV-L2 soft-delete. Sets `deleted_at`; never removes the row.
    public func tombstone(_ id: String) throws {
        let fmt = ISO8601DateFormatter()
        try dbQueue.write { db in
            guard var row = try ExerciseRow.fetchOne(db, key: id) else {
                throw ExerciseLibraryError.notFound(id)
            }
            guard row.deletedAt == nil else { return } // idempotent
            row.deletedAt = fmt.string(from: Date())
            row.updatedAt = fmt.string(from: Date())
            try row.update(db)
        }
    }

    /// BR-008: clears `deleted_at`, bumps `updated_at`. No expiry.
    public func restore(_ id: String) throws {
        let fmt = ISO8601DateFormatter()
        try dbQueue.write { db in
            guard var row = try ExerciseRow.fetchOne(db, key: id) else {
                throw ExerciseLibraryError.notFound(id)
            }
            guard row.deletedAt != nil else { return } // idempotent
            row.deletedAt = nil
            row.updatedAt = fmt.string(from: Date())
            try row.update(db)
        }
    }
}
