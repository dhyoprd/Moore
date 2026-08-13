// contractId: SC-exercises @1.0.0
// GRDB-backed DAO for the `exercise` table.
// This is the ONLY file in MooreExercises allowed to import GRDB. All other layers
// see plain `Exercise` structs. Typed methods replace raw SQL for callers.
//
// Column names are the REAL schema (#32 reconciliation): 0001's camelCase columns
// (exerciseType, equipmentSlug, isCustom, createdAt, updatedAt, deletedAt) plus
// the rewritten 0004's additions (category, defaultMetric, defaultRestSec, and
// the BR-001 key `name_normalized`, which keeps its snake_case spelling).

import Foundation
import GRDB

/// Storage-backed exercise row, mapped from GRDB. Mirrors `Exercise` in Models.swift.
public struct ExerciseRow: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "exercise"

    public var id: String
    public var name: String
    /// 0001's NOT NULL type column. Derived on write from the domain row
    /// (customs → 'custom'; built-ins → 'cardio' when the default metric is
    /// duration, else 'strength' — the INV-IM8 precedent).
    public var exerciseType: String
    public var nameNormalized: String
    /// NULL = unclassified (import-created customs until the user files them);
    /// reads resolve NULL → `.other`, the taxonomy's catch-all bucket.
    public var category: String?
    /// NULL = unset; reads resolve NULL → `.reps` (the v1 default metric).
    public var defaultMetric: String?
    /// Maps the 0001 `equipmentSlug` column; NULL = `.other`.
    public var equipment: String?
    public var isCustom: Int
    public var defaultRestSec: Int?
    public var createdAt: String   // ISO-8601 UTC
    public var updatedAt: String
    public var deletedAt: String?

    /// Property → real column name (GRDB uses the coding keys for both the
    /// PersistableRecord encoding and the FetchableRecord decoding).
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case exerciseType
        case nameNormalized = "name_normalized"
        case category
        case defaultMetric
        case equipment = "equipmentSlug"
        case isCustom
        case defaultRestSec
        case createdAt
        case updatedAt
        case deletedAt
    }

    public func toDomain() throws -> Exercise {
        // NULL-safe resolution: unclassified customs read as `.other`, unset
        // metrics as `.reps`, missing equipment as `.other` (#32 — the real
        // schema leaves these columns NULL until the app classifies the row).
        let cat = category.flatMap(ExerciseCategory.init(rawValue:)) ?? .other
        let met = defaultMetric.flatMap(DefaultMetric.init(rawValue:)) ?? .reps
        let eqp = equipment.flatMap(ExerciseEquipment.init(rawValue:)) ?? .other
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
        // INV-IM8: duration metric ⇔ exerciseType='cardio'; customs are 'custom'.
        self.exerciseType = domain.isCustom
            ? "custom"
            : (domain.defaultMetric == .duration ? "cardio" : "strength")
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
        exerciseType: String,
        nameNormalized: String,
        category: String?,
        defaultMetric: String?,
        equipment: String?,
        isCustom: Int,
        defaultRestSec: Int?,
        createdAt: String,
        updatedAt: String,
        deletedAt: String?
    ) {
        self.id = id
        self.name = name
        self.exerciseType = exerciseType
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
    /// existing rows untouched (they keep their own createdAt/updatedAt). Every
    /// built-in row carries `category` + `defaultMetric` (+ `name_normalized` and
    /// the derived `exerciseType`) into the exercise table (#32 AC-2).
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
            var sql = "SELECT * FROM exercise WHERE deletedAt IS NULL"
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
                .filter(Column("name_normalized") == normalized && Column("deletedAt") == nil)
                .fetchOne(db) {
                return .matchedExisting(try existing.toDomain())
            }
            // (b)/(c) tombstoned row sharing the normalized name?
            if let tombstoned = try ExerciseRow
                .filter(Column("name_normalized") == normalized && Column("deletedAt") != nil)
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
                exerciseType: "custom",
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

    /// INV-L2 soft-delete. Sets `deletedAt`; never removes the row.
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

    /// BR-008: clears `deletedAt`, bumps `updatedAt`. No expiry.
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
