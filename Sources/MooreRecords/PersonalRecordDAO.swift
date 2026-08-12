// contractId: SC-prs @1.0.0
// §5 seam-2 DAO. GRDB-backed persistence for `personal_record` (post-0008
// shape). Two write paths per the ticket ruling:
//   writeFromSet — LIVE: baseline row must already exist; strict exceed writes
//                  + returns the cue descriptor. Never seeds. One transaction.
//   rederive     — MAINTENANCE: seeds missing baselines, rewrites moved
//                  bookmarks, tombstones dead kinds. Never cues.

import Foundation
import GRDB

extension PersonalRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "personal_record"
}

public struct PersonalRecordDAO: Sendable {
    public let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Live write path

    /// BR-002/BR-006: evaluate the just-completed set against EXISTING baseline
    /// rows only. If any kind strictly exceeds, its row updates in the same
    /// transaction and the returned PRWrite.fired carries the single headline
    /// cue for the caller to dispatch (`cue.pr.achieved`). No baseline row ⇒
    /// nil — first-touch writes nothing, fires nothing (ruling).
    @discardableResult
    public func writeFromSet(_ setId: String) throws -> PRWrite? {
        try dbQueue.write { db in
            guard let set = try fetchReferenceSet(id: setId, in: db) else { return nil }
            let baselines = try fetchBaselines(exerciseId: set.exerciseId, in: db)
            guard let write = PREngine.processNewSet(set: set, baselines: baselines) else { return nil }

            let now = ISO8601DateFormatter().string(from: Date())
            for kind in write.written {
                guard let v = write.values[kind] else { continue }
                try upsertRow(
                    db, exerciseId: set.exerciseId, sessionId: set.sessionId,
                    setId: set.id, kind: kind, value: v,
                    achievedAt: set.completedAt ?? now, now: now
                )
            }
            return write
        }
    }

    // MARK: - Maintenance write path

    /// BR-007/BR-008/BR-009: recompute the exercise's per-kind bookmark from
    /// full live history (INV-PR4). Seeds missing rows, rewrites moved holders,
    /// tombstones dead kinds. Only rows whose (value, holder) actually changed
    /// are touched — no updatedAt churn (BR-007 tail). Silent (no cue).
    public func rederive(exerciseId: String) throws {
        try dbQueue.write { db in
            let history = try fetchExerciseHistory(exerciseId: exerciseId, in: db)
            let target = PREngine.rederive(exerciseHistory: history)
            let now = ISO8601DateFormatter().string(from: Date())

            for kind in PRKind.allCases {
                let existing = try fetchRow(exerciseId: exerciseId, kind: kind, in: db)
                switch (existing, target[kind]) {
                case (.none, .none):
                    continue
                case let (.some(row), .some(t)):
                    if row.value != t.value || row.setId != t.setId {
                        try db.execute(
                            sql: """
                                UPDATE personal_record
                                   SET value = ?, setId = ?, sessionId = ?, achievedAt = ?, updatedAt = ?
                                 WHERE id = ?
                                """,
                            arguments: [t.value, t.setId, t.sessionId ?? row.sessionId, t.achievedAt ?? row.achievedAt, now, row.id]
                        )
                    }
                case (.none, .some(let t)):
                    try insertRow(
                        db, exerciseId: exerciseId, sessionId: t.sessionId ?? "",
                        setId: t.setId, kind: kind, value: t.value,
                        achievedAt: t.achievedAt ?? now, now: now
                    )
                case (.some(let row), .none):
                    try db.execute(
                        sql: "UPDATE personal_record SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                        arguments: [now, now, row.id]
                    )
                }
            }
        }
    }

    // MARK: - Read seams

    /// INV-PR2 bookmark read for an exercise.
    public func fetchBest(exerciseId: String) throws -> [PRKind: PersonalRecord] {
        try dbQueue.read { db in try fetchBaselines(exerciseId: exerciseId, in: db) }
    }

    /// BR-010/INV-PR5: Summary banner + cards input. Precedence-ordered.
    public func fetchSessionPRs(sessionId: String) throws -> [PersonalRecord] {
        try dbQueue.read { db in
            let rows = try PersonalRecord
                .filter(Column("sessionId") == sessionId && Column("deletedAt") == nil)
                .fetchAll(db)
            return rows.sorted { $0.kind.precedenceRank < $1.kind.precedenceRank }
        }
    }

    // MARK: - Internals

    private func fetchRow(exerciseId: String, kind: PRKind, in db: Database) throws -> PersonalRecord? {
        try PersonalRecord
            .filter(Column("exerciseId") == exerciseId && Column("kind") == kind.rawValue && Column("deletedAt") == nil)
            .fetchOne(db)
    }

    private func fetchBaselines(exerciseId: String, in db: Database) throws -> [PRKind: PersonalRecord] {
        var out: [PRKind: PersonalRecord] = [:]
        for kind in PRKind.allCases {
            if let row = try fetchRow(exerciseId: exerciseId, kind: kind, in: db) {
                out[kind] = row
            }
        }
        return out
    }

    private func fetchReferenceSet(id: String, in db: Database) throws -> ReferenceSessionSet? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT cs.id, cs.sessionId, cs.exerciseId, cs.status, cs.setClass,
                   cs.actualWeight, cs.actualReps, cs.actualDuration, cs.completedAt,
                   e.exerciseType
              FROM completed_set cs
              JOIN exercise e ON e.id = cs.exerciseId
             WHERE cs.id = ? AND cs.deletedAt IS NULL
            """, arguments: [id]) else { return nil }
        return referenceSet(from: row)
    }

    private func fetchExerciseHistory(exerciseId: String, in db: Database) throws -> [ReferenceSessionSet] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT cs.id, cs.sessionId, cs.exerciseId, cs.status, cs.setClass,
                   cs.actualWeight, cs.actualReps, cs.actualDuration, cs.completedAt,
                   e.exerciseType
              FROM completed_set cs
              JOIN exercise e ON e.id = cs.exerciseId
             WHERE cs.exerciseId = ? AND cs.deletedAt IS NULL
            """, arguments: [exerciseId])
        return rows.map(referenceSet(from:))
    }

    /// Metric resolution: SC-exercises' `defaultMetric` column lands via the
    /// 0004 rewrite (docs/MIGRATION-INTEGRATION-NOTE.md); until then the v1
    /// duration surface is exerciseType='cardio'. Verifier fixtures mirror this.
    private func referenceSet(from row: Row) -> ReferenceSessionSet {
        let type: String = row["exerciseType"]
        let classRaw: String? = row["setClass"]
        let statusRaw: String = row["status"]
        return ReferenceSessionSet(
            id: row["id"],
            sessionId: row["sessionId"],
            exerciseId: row["exerciseId"],
            status: SetStatus(rawValue: statusRaw) ?? .planned,
            setClass: classRaw.flatMap(SetClass.init(rawValue:)),
            actualWeight: row["actualWeight"],
            actualReps: row["actualReps"],
            actualDuration: row["actualDuration"],
            completedAt: row["completedAt"],
            exerciseDefaultMetric: (type == "cardio") ? .duration : .reps
        )
    }

    /// INV-PR2 upsert: update-in-place when a live row exists, else insert.
    /// Tombstones stale duplicate live rows so the one-row-per-kind invariant
    /// survives legacy 0001 writes. In the live path (writeFromSet) the insert
    /// branch is unreachable — processNewSet only returns kinds with existing
    /// rows — but the shape is shared with rederive's seed step.
    private func upsertRow(_ db: Database, exerciseId: String, sessionId: String, setId: String, kind: PRKind, value: Double, achievedAt: String, now: String) throws {
        let live = try PersonalRecord
            .filter(Column("exerciseId") == exerciseId && Column("kind") == kind.rawValue && Column("deletedAt") == nil)
            .order(Column("achievedAt").desc)
            .fetchAll(db)
        if let head = live.first {
            try db.execute(
                sql: """
                    UPDATE personal_record
                       SET value = ?, setId = ?, sessionId = ?, achievedAt = ?, updatedAt = ?
                     WHERE id = ?
                    """,
                arguments: [value, setId, sessionId, achievedAt, now, head.id]
            )
            for stale in live.dropFirst() {
                try db.execute(
                    sql: "UPDATE personal_record SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                    arguments: [now, now, stale.id]
                )
            }
        } else {
            try insertRow(db, exerciseId: exerciseId, sessionId: sessionId, setId: setId, kind: kind, value: value, achievedAt: achievedAt, now: now)
        }
    }

    private func insertRow(_ db: Database, exerciseId: String, sessionId: String, setId: String?, kind: PRKind, value: Double, achievedAt: String, now: String) throws {
        try db.execute(
            sql: """
                INSERT INTO personal_record
                    (id, exerciseId, sessionId, setId, kind, value, achievedAt, createdAt, updatedAt, deletedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
            arguments: [UUID().uuidString.lowercased(), exerciseId, sessionId, setId, kind.rawValue, value, achievedAt, now, now]
        )
    }
}
