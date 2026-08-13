// Ticket #43 — seam-2 DAO for the self-validation storage added by
// 0012_validation_metrics.sql: app_open_event (retention signal),
// validation_baseline (Hevy logging-speed reference), and the two manual gate
// confirmations (builder-attested facts that cannot be derived on-device).
//
// Scope discipline: session/set reads for the gate stay AnalyticsDAO's frozen
// read seam (SC-analytics INV-A1 — no write path there); this DAO owns ONLY the
// 0012 tables + two app_setting keys. Tombstone rule per SC-foundation BR-003:
// no DELETE anywhere — baseline removal flips deletedAt. INV-1: ids are
// client-generated UUIDs; INV-2: every UPDATE bumps updatedAt.

import Foundation
import GRDB

public struct ValidationDAO: Sendable {
    public let dbQueue: DatabaseQueue

    /// app_setting keys for the two human-judged gate conditions (#4 trigger
    /// lines 2–3). Stored as "1"/"0" like every other app_setting flag.
    public static let displacementConfirmedKey = "validationDisplacementConfirmed"
    public static let retentionConfirmedKey = "validationRetentionConfirmed"

    /// The one validation_baseline metricKey of v1: the Hevy logging-speed
    /// baseline in seconds per completed set.
    public static let hevySpeedBaselineKey = "hevySecondsPerSet"

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: App-open events (retention signal — one row per foreground)

    /// Append one foreground event. Events are immutable once written; callers
    /// (boot + scene foreground) own the once-per-foreground discipline.
    @discardableResult
    public func recordAppOpen(at now: String) throws -> ValidationOpenEvent {
        let event = ValidationOpenEvent(
            id: UUID().uuidString.lowercased(),
            openedAt: now
        )
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_open_event (id, openedAt, createdAt) VALUES (?, ?, ?)
                    """,
                arguments: [event.id, event.openedAt, now]
            )
        }
        return event
    }

    /// Full open-event timeline, ascending (retention derives over all of it —
    /// the windowing happens in ValidationMetricsEngine, never in SQL).
    public func fetchOpenEvents() throws -> [ValidationOpenEvent] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, openedAt FROM app_open_event ORDER BY openedAt ASC
                """).map { row in
                    ValidationOpenEvent(id: row["id"], openedAt: row["openedAt"])
                }
        }
    }

    // MARK: Baseline (Hevy logging-speed reference)

    /// The live baseline for a metricKey; nil when never entered (or the row
    /// is tombstoned — INV-3 default filter).
    public func fetchBaseline(metricKey: String) throws -> ValidationBaseline? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, metricKey, value, unit, recordedAt, createdAt, updatedAt, deletedAt
                  FROM validation_baseline
                 WHERE metricKey = ? AND deletedAt IS NULL
                 ORDER BY recordedAt DESC
                """, arguments: [metricKey]).map { row in
                    ValidationBaseline(
                        id: row["id"],
                        metricKey: row["metricKey"],
                        value: row["value"],
                        unit: row["unit"],
                        recordedAt: row["recordedAt"],
                        createdAt: row["createdAt"],
                        updatedAt: row["updatedAt"],
                        deletedAt: row["deletedAt"]
                    )
                }
        }
    }

    /// Upsert the live baseline for a metricKey: UPDATE the live row (bumping
    /// updatedAt, INV-2) or INSERT when absent. One live row per metricKey is
    /// enforced by validation_baseline_key_idx (0012).
    @discardableResult
    public func upsertBaseline(
        metricKey: String,
        value: Double,
        unit: String,
        recordedAt: String,
        at now: String
    ) throws -> ValidationBaseline {
        if let existing = try fetchBaseline(metricKey: metricKey) {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE validation_baseline
                           SET value = ?, unit = ?, recordedAt = ?, updatedAt = ?
                         WHERE id = ? AND deletedAt IS NULL
                        """,
                    arguments: [value, unit, recordedAt, now, existing.id]
                )
            }
            var updated = existing
            updated.value = value
            updated.unit = unit
            updated.recordedAt = recordedAt
            updated.updatedAt = now
            return updated
        }
        let row = ValidationBaseline(
            id: UUID().uuidString.lowercased(),
            metricKey: metricKey,
            value: value,
            unit: unit,
            recordedAt: recordedAt,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO validation_baseline
                        (id, metricKey, value, unit, recordedAt, createdAt, updatedAt, deletedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                arguments: [row.id, row.metricKey, row.value, row.unit, row.recordedAt, row.createdAt, row.updatedAt]
            )
        }
        return row
    }

    // MARK: Manual gate confirmations (#4 trigger lines 2–3)

    public func fetchConfirmation(key: String) throws -> Bool {
        try dbQueue.read { db in
            let value = try String.fetchOne(
                db,
                sql: "SELECT value FROM app_setting WHERE key = ?",
                arguments: [key]
            )
            return value == "1"
        }
    }

    /// Upsert the flag row (app_setting shape: key/value/updatedAt).
    public func setConfirmation(key: String, confirmed: Bool, at now: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_setting (key, value, updatedAt) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
                    """,
                arguments: [key, confirmed ? "1" : "0", now]
            )
        }
    }
}
