// contractId: SC-rest @1.0.0
// GRDB-backed persistence for level-4 global rest defaults ONLY (§5). Timer
// state is in-memory only (INV-T2) — no DAO exists for durations, timestamps,
// or the FSM state; this DAO touches nothing but the `app_setting` rows.
// Follows SC-foundation BR-003: reads/writes bump `updatedAt`; no DELETE.

import Foundation
import GRDB

public struct RestSettingsDAO: Sendable {
    public let dbQueue: DatabaseQueue

    private static let compoundKey = "defaultRestCompoundSec"
    private static let isolationKey = "defaultRestIsolationSec"

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// The current settings, falling back to #9 v1 defaults for any missing or
    /// unreadable row (INV-S2 guarantees both rows after 0007; the fallback keeps
    /// the read total even on a foreign database that has not yet migrated).
    public func fetch() throws -> RestSettings {
        let defaults = RestSettings.default
        return try dbQueue.read { db in
            let compound = try rawValue(key: Self.compoundKey, in: db).flatMap(Int.init) ?? defaults.defaultRestCompoundSec
            let isolation = try rawValue(key: Self.isolationKey, in: db).flatMap(Int.init) ?? defaults.defaultRestIsolationSec
            return RestSettings(defaultRestCompoundSec: compound, defaultRestIsolationSec: isolation)
        }
    }

    /// Upserts either or both defaults (nil = leave unchanged), bumping each
    /// touched row's `updatedAt` (INV-S1 / SC-foundation INV-2).
    public func update(compoundSec: Int? = nil, isolationSec: Int? = nil) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbQueue.write { db in
            if let compoundSec {
                try upsert(key: Self.compoundKey, value: String(compoundSec), updatedAt: now, in: db)
            }
            if let isolationSec {
                try upsert(key: Self.isolationKey, value: String(isolationSec), updatedAt: now, in: db)
            }
        }
    }

    // MARK: - Internals

    private func rawValue(key: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM app_setting WHERE key = ?", arguments: [key])
    }

    private func upsert(key: String, value: String, updatedAt: String, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO app_setting (key, value, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
                """,
            arguments: [key, value, updatedAt]
        )
    }
}
