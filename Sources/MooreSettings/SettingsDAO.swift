// contractId: SC-settings @1.0.0
// Seam-2 GRDB persistence for the Settings + Data & sync surface (#28).
//
// Assumes the full migration chain has been applied, incl. 0007_rest_fields
// (app_setting + rest defaults, SC-rest §3d) and 0009_body_metrics (this
// module's rebuild of body_metric). `MooreSettingsMigrations` below registers
// the 0009 step for module-level runners.
//
// Tombstone rule (SC-foundation BR-003): no DELETE anywhere — deletes flip
// `deletedAt`; restore clears it (BR-010/INV-ST4). Reads filter
// `deletedAt IS NULL` unless explicitly raw.

import Foundation
import GRDB

// MARK: - Module migration runner (0009)

public enum MooreSettingsMigrationError: Error {
    case migrationResourceMissing(String)
}

public enum MooreSettingsMigrations {
    public static let migrationNames: [String] = [
        "0009_body_metrics.sql",
    ]

    public static func migrate(_ writer: some DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        for name in migrationNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw MooreSettingsMigrationError.migrationResourceMissing(name)
            }
            let sql = try String(contentsOf: url, encoding: .utf8)
            migrator.registerMigration(name) { db in
                try db.execute(sql: sql)
            }
        }

        try migrator.migrate(writer)
    }
}

// MARK: - Row types

/// Post-0009 body_metric row (§3b). Kind/unit are stringly-typed on purpose:
/// the vocabulary is enforced by `SettingsEngine.validateBodyMetric` (BR-006),
/// not re-encoded in a frozen enum (measurement carries a free label + unit).
public struct SettingsBodyMetric: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var label: String?
    public var value: Double
    public var unit: String
    public var recordedAt: String
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?

    public init(
        id: String,
        kind: String,
        label: String?,
        value: Double,
        unit: String,
        recordedAt: String,
        createdAt: String,
        updatedAt: String,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.value = value
        self.unit = unit
        self.recordedAt = recordedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

extension SettingsBodyMetric: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "body_metric"
}

/// One row of the tombstone-management list (BR-010).
public struct TombstonedExercise: Equatable, Sendable {
    public var id: String
    public var name: String
    public var exerciseType: String
    public var deletedAt: String

    public init(id: String, name: String, exerciseType: String, deletedAt: String) {
        self.id = id
        self.name = name
        self.exerciseType = exerciseType
        self.deletedAt = deletedAt
    }
}

public enum SettingsDAOError: Error, Equatable {
    case invalidBodyMetric(SettingsEngine.BodyMetricValidationError)
    case bodyMetricNotFound(String)
    case exportNotFileBacked
}

// MARK: - DAO

public struct SettingsDAO: Sendable {
    public let dbQueue: DatabaseQueue

    private static let weightUnitKey = "weightUnit"
    private static let compoundKey = "defaultRestCompoundSec"
    private static let isolationKey = "defaultRestIsolationSec"

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: Settings (BR-001, BR-005, BR-014)

    /// Total read (BR-014): absent rows fall back to .kg / 180 / 90. Zero
    /// writes on a fresh database.
    public func fetchSettings() throws -> AppSettingsSnapshot {
        try dbQueue.read { db in
            let unitRaw = try settingValue(key: Self.weightUnitKey, in: db)
            let unit = WeightUnit(rawValue: unitRaw ?? "") ?? AppSettingsSnapshot.default.weightUnit
            let compound = try settingValue(key: Self.compoundKey, in: db).flatMap(Int.init)
                ?? AppSettingsSnapshot.default.defaultRestCompoundSec
            let isolation = try settingValue(key: Self.isolationKey, in: db).flatMap(Int.init)
                ?? AppSettingsSnapshot.default.defaultRestIsolationSec
            return AppSettingsSnapshot(
                weightUnit: unit,
                defaultRestCompoundSec: compound,
                defaultRestIsolationSec: isolation
            )
        }
    }

    /// BR-001: the ONLY write a unit toggle performs — one settings row.
    /// No weight value anywhere else is touched (INV-ST1).
    public func setWeightUnit(_ unit: WeightUnit, at now: String) throws {
        try upsertSetting(key: Self.weightUnitKey, value: unit.rawValue, at: now)
    }

    /// BR-005: edits SC-rest's two level-4 keys. `nil` = leave unchanged.
    /// Resolution itself stays SC-rest BR-001's job; this surface only writes.
    public func updateRestDefaults(compoundSec: Int? = nil, isolationSec: Int? = nil, at now: String) throws {
        if let compoundSec {
            try upsertSetting(key: Self.compoundKey, value: String(compoundSec), at: now)
        }
        if let isolationSec {
            try upsertSetting(key: Self.isolationKey, value: String(isolationSec), at: now)
        }
    }

    // MARK: Body metrics CRUD (BR-006 / BR-007)

    /// Validates via the pure engine gate (BR-006) then inserts. Returns the
    /// inserted row. Reject = throw, no partial write.
    @discardableResult
    public func addBodyMetric(
        kind: String,
        label: String?,
        value: Double,
        unit: String,
        recordedAt: String,
        at now: String
    ) throws -> SettingsBodyMetric {
        if let error = SettingsEngine.validateBodyMetric(kind: kind, label: label, value: value, unit: unit) {
            throw SettingsDAOError.invalidBodyMetric(error)
        }
        let metric = SettingsBodyMetric(
            id: UUID().uuidString.lowercased(),
            kind: kind,
            label: kind == "measurement" ? label : nil,
            value: value,
            unit: unit,
            recordedAt: recordedAt,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )
        try dbQueue.write { db in try metric.insert(db) }
        return metric
    }

    /// Trend list (BR-007): live rows, recordedAt DESC (SC-foundation BR-005),
    /// optional kind filter. No charting, no aggregation.
    public func listBodyMetrics(kind: String? = nil) throws -> [SettingsBodyMetric] {
        try dbQueue.read { db in
            if let kind {
                return try SettingsBodyMetric.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM body_metric
                         WHERE deletedAt IS NULL AND kind = ?
                         ORDER BY recordedAt DESC, createdAt DESC
                        """,
                    arguments: [kind]
                )
            }
            return try SettingsBodyMetric.fetchAll(
                db,
                sql: """
                    SELECT * FROM body_metric
                     WHERE deletedAt IS NULL
                     ORDER BY recordedAt DESC, createdAt DESC
                    """
            )
        }
    }

    /// Raw scan incl. tombstones (SC-foundation V14-style escape hatch).
    public func fetchBodyMetricsIncludingTombstoned() throws -> [SettingsBodyMetric] {
        try dbQueue.read { db in try SettingsBodyMetric.fetchAll(db) }
    }

    /// BR-006 update: re-validates, bumps `updatedAt` (SC-foundation INV-2).
    public func updateBodyMetric(
        id: String,
        value: Double,
        unit: String,
        label: String?,
        recordedAt: String,
        at now: String
    ) throws {
        let kind = try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT kind FROM body_metric WHERE id = ? AND deletedAt IS NULL",
                arguments: [id]
            )
        }
        guard let kind else { throw SettingsDAOError.bodyMetricNotFound(id) }
        if let error = SettingsEngine.validateBodyMetric(kind: kind, label: label, value: value, unit: unit) {
            throw SettingsDAOError.invalidBodyMetric(error)
        }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE body_metric
                       SET value = ?, unit = ?, label = ?, recordedAt = ?, updatedAt = ?
                     WHERE id = ? AND deletedAt IS NULL
                    """,
                arguments: [value, unit, kind == "measurement" ? label : nil, recordedAt, now, id]
            )
        }
    }

    /// BR-006 delete = tombstone (SC-foundation BR-003). Never a hard delete.
    public func softDeleteBodyMetric(id: String, at now: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE body_metric SET deletedAt = ?, updatedAt = ? WHERE id = ? AND deletedAt IS NULL",
                arguments: [now, now, id]
            )
        }
    }

    // MARK: Tombstone management (BR-010)

    /// Custom exercises the user tombstoned, deletedAt DESC (BR-010). The
    /// isCustom filter keeps built-in library rows out — they are not
    /// user-owned. Engine's pure filter/sort is mirrored here in SQL; both
    /// agree by construction (the JS mirror checks the engine form).
    public func listTombstonedCustomExercises() throws -> [TombstonedExercise] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, exerciseType, deletedAt
                      FROM exercise
                     WHERE isCustom = 1 AND deletedAt IS NOT NULL
                     ORDER BY deletedAt DESC, name ASC
                    """
            )
            return rows.map { row in
                TombstonedExercise(
                    id: row["id"],
                    name: row["name"],
                    exerciseType: row["exerciseType"],
                    deletedAt: row["deletedAt"]
                )
            }
        }
    }

    /// Restore is the inverse of tombstone (INV-ST4): clears `deletedAt`,
    /// bumps `updatedAt`, nothing else. Restoring a live row is a no-op.
    public func restoreExercise(id: String, at now: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE exercise
                       SET deletedAt = NULL, updatedAt = ?
                     WHERE id = ? AND deletedAt IS NOT NULL
                    """,
                arguments: [now, id]
            )
        }
    }

    // MARK: Data & sync (BR-008 / BR-009)

    /// SELECT dumps across EVERY table in the file — core ten and
    /// `__legacy_*` remnants alike (INV-ST3). Tables without a `deletedAt`
    /// column report tombstoneCount 0.
    public func exportSelectDumps() throws -> [SettingsEngine.TableStats] {
        try dbQueue.read { db in
            let tables = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                     WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                     ORDER BY name
                    """
            )
            var dumps: [SettingsEngine.TableStats] = []
            for table in tables {
                let total = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM \"\(table)\""
                ) ?? 0
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
                let hasTombstoneColumn = columns.contains { ($0["name"] as String?) == "deletedAt" }
                let tombstoned = hasTombstoneColumn
                    ? (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\" WHERE deletedAt IS NOT NULL") ?? 0)
                    : 0
                dumps.append(SettingsEngine.TableStats(table: table, rowCount: total, tombstoneCount: tombstoned))
            }
            return dumps
        }
    }

    /// The BR-009 manifest for this database at `exportedAt`.
    public func exportManifest(exportedAt: String) throws -> SettingsEngine.ExportManifest {
        SettingsEngine.buildExportManifest(tableStats: try exportSelectDumps(), exportedAt: exportedAt)
    }

    /// BR-008: full SQLite file copy — every table incl. tombstones + legacy
    /// remnants, plannedX verbatim. GRDB's backup-based copy is page-complete;
    /// a WAL checkpoint first folds any pending journal into the main file.
    public func exportFullCopy(toPath destinationPath: String) throws {
        let sourcePath = dbQueue.path
        guard !sourcePath.isEmpty else { throw SettingsDAOError.exportNotFileBacked }
        try dbQueue.read { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try Database.copy(from: sourcePath, to: destinationPath)
    }

    // MARK: Internals

    private func settingValue(key: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM app_setting WHERE key = ?", arguments: [key])
    }

    /// Upsert by key; bumps `updatedAt` (SC-foundation INV-2, SC-rest INV-S1).
    private func upsertSetting(key: String, value: String, at now: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_setting (key, value, updatedAt) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
                    """,
                arguments: [key, value, now]
            )
        }
    }
}
