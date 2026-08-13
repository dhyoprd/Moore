// contractId: SC-import @1.0.0
// §4 BR-015/BR-016, §5 seam-2. GRDB-backed atomic apply of an ImportPlan:
// ONE transaction — custom exercises → sessions (INSERT-OR-IGNORE by importKey)
// → completed sets → per-exercise PR re-derivation. Any failure rolls back
// everything (INV-IM2); no partial-import state exists.
//
// PR re-derivation mirrors SC-prs@1.0.0 BR-009/INV-PR4 (PREngine.rederive):
// per-kind bookmark over the exercise's full live history — seeds missing rows,
// re-points moved holders, tombstones dead kinds; silent, never cues. It runs
// inline (not via PersonalRecordDAO.rederive) so the whole apply stays a single
// transaction.

import Foundation
import GRDB

public struct ImportSummary: Equatable, Sendable {
    public var sessionsImported: Int
    public var sessionsSkippedAlreadyImported: Int
    public var setsImported: Int
    public var exercisesCreated: Int

    public init(sessionsImported: Int, sessionsSkippedAlreadyImported: Int, setsImported: Int, exercisesCreated: Int) {
        self.sessionsImported = sessionsImported
        self.sessionsSkippedAlreadyImported = sessionsSkippedAlreadyImported
        self.setsImported = setsImported
        self.exercisesCreated = exercisesCreated
    }
}

public struct HevyImportDAO: Sendable {
    public let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// BR-015: atomic apply. `plan.sessions` flagged `alreadyImported` are
    /// skipped wholesale (BR-013); the INSERT-OR-IGNORE on the 0003 UNIQUE
    /// partial index is the backstop for anything the plan didn't know about.
    @discardableResult
    public func apply(_ plan: ImportPlan) throws -> ImportSummary {
        try dbQueue.write { db in
            let now = plan.now
            var summary = ImportSummary(sessionsImported: 0, sessionsSkippedAlreadyImported: 0, setsImported: 0, exercisesCreated: 0)

            // Live exercise snapshot: normalized-name → row, for the custom-create
            // backstop and metric resolution. #32: the rewritten 0004 landed
            // `name_normalized`, so stored values are authoritative (rows written
            // before the column existed were backfilled by the migration itself).
            let liveExercises = try Row.fetchAll(db, sql: """
                SELECT id, name, name_normalized, exerciseType, isCustom
                  FROM exercise
                 WHERE deletedAt IS NULL
                """)
            var exerciseIdByNormalized: [String: String] = [:]
            var metricByExerciseId: [String: String] = [:]      // "reps" | "duration"
            for row in liveExercises {
                let id: String = row["id"]
                let name: String = row["name"]
                let normalized: String? = row["name_normalized"]
                let type: String = row["exerciseType"]
                exerciseIdByNormalized[normalized ?? HevyImportEngine.normalize(name)] = id
                metricByExerciseId[id] = (type == "cardio") ? "duration" : "reps"
            }

            // ---- 1. Custom exercises (BR-009/INV-IM8).
            var idForNewExercise: [String: String] = [:]
            for newExercise in plan.newExercises {
                if let existingId = exerciseIdByNormalized[newExercise.normalizedName] {
                    idForNewExercise[newExercise.normalizedName] = existingId   // backstop: never double-create
                    continue
                }
                let id = UUID().uuidString.lowercased()
                // INV-IM8: duration metric ⇔ exerciseType='cardio' (v1 representation;
                // SC-prs metric-resolution precedent). #32: customs also carry their
                // BR-001 materialized name + defaultMetric; category stays NULL until
                // the user classifies the exercise (reads resolve NULL → other/reps).
                let exerciseType = (newExercise.metric == "duration") ? "cardio" : "custom"
                try db.execute(sql: """
                    INSERT INTO exercise (id, name, exerciseType, isCustom, defaultMetric, name_normalized, createdAt, updatedAt)
                    VALUES (?, ?, ?, 1, ?, ?, ?, ?)
                    """, arguments: [id, newExercise.name, exerciseType, newExercise.metric, newExercise.normalizedName, now, now])
                exerciseIdByNormalized[newExercise.normalizedName] = id
                metricByExerciseId[id] = newExercise.metric
                idForNewExercise[newExercise.normalizedName] = id
                summary.exercisesCreated += 1
            }

            // ---- 2+3. Sessions (INSERT-OR-IGNORE by importKey) then their sets.
            var affectedExerciseIds: [String] = []
            var affectedSeen: Set<String> = []
            for session in plan.sessions {
                if session.alreadyImported {
                    summary.sessionsSkippedAlreadyImported += 1
                    continue
                }
                let sessionId = UUID().uuidString.lowercased()
                try db.execute(sql: """
                    INSERT OR IGNORE INTO workout_session
                        (id, name, notes, startedAt, endedAt, importSource, importKey, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, 'hevy', ?, ?, ?)
                    """, arguments: [
                        sessionId, session.name, session.notes, session.startedAt,
                        session.endedAt, session.importKey, now, now,
                    ])
                guard db.changesCount > 0 else {
                    // UNIQUE(importKey) backstop: already imported elsewhere.
                    summary.sessionsSkippedAlreadyImported += 1
                    continue
                }
                summary.sessionsImported += 1

                for set in session.sets {
                    let exerciseId: String
                    switch set.exerciseRef {
                    case .existing(let id):
                        exerciseId = id
                    case .new(let normalizedName):
                        guard let id = idForNewExercise[normalizedName] else {
                            // Plan/apply desync — roll the whole transaction back.
                            throw HevyImportDAOError.unresolvedExercise(normalizedName)
                        }
                        exerciseId = id
                    }
                    try db.execute(sql: """
                        INSERT INTO completed_set
                            (id, sessionId, exerciseId, sortOrder,
                             plannedWeight, plannedReps, plannedDuration,
                             actualWeight, actualReps, actualDuration,
                             status, completedAt, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?, 'completed', ?, ?, ?)
                        """, arguments: [
                            UUID().uuidString.lowercased(), sessionId, exerciseId, set.sortOrder,
                            set.actualWeight, set.actualReps, set.actualDuration,
                            set.completedAt, now, now,
                        ])
                    summary.setsImported += 1
                    if !affectedSeen.contains(exerciseId) {
                        affectedSeen.insert(exerciseId)
                        affectedExerciseIds.append(exerciseId)
                    }
                }
            }

            // ---- 4. PR re-derivation, SC-prs BR-009 semantics (BR-016).
            for exerciseId in affectedExerciseIds {
                try rederivePRs(exerciseId: exerciseId, metric: metricByExerciseId[exerciseId] ?? "reps", now: now, in: db)
            }

            return summary
        }
    }

    // MARK: - Maintenance-path PR re-derivation (mirror of PREngine.rederive)

    private func rederivePRs(exerciseId: String, metric: String, now: String, in db: Database) throws {
        let history = try Row.fetchAll(db, sql: """
            SELECT id, sessionId, status, setClass, actualWeight, actualReps, actualDuration, completedAt
              FROM completed_set
             WHERE exerciseId = ? AND deletedAt IS NULL
            """, arguments: [exerciseId])

        struct Candidate {
            let setId: String
            let sessionId: String
            let completedAt: String
            let values: [String: Double]      // kind → computed value
        }
        // BR-001 (SC-prs): completed work sets only.
        let work = history.filter { row in
            let status: String = row["status"]
            let setClass: String? = row["setClass"]
            return status == "completed" && (setClass ?? "work") == "work"
        }

        let kinds = ["max_1rm", "max_volume", "max_reps", "max_duration"]
        var bestValue: [String: Double] = [:]
        var bestHolder: [String: Candidate] = [:]

        func value(of kind: String, weight: Double?, reps: Int?, duration: Int?) -> Double? {
            switch kind {
            case "max_1rm":
                guard let w = weight, w > 0, let r = reps, r > 0 else { return nil }
                return w * (1.0 + Double(r) / 30.0)                     // Epley
            case "max_volume":
                guard let w = weight, w > 0, let r = reps, r > 0 else { return nil }
                return w * Double(r)
            case "max_reps":
                guard let r = reps, r > 0 else { return nil }
                return Double(r)
            case "max_duration":
                guard metric == "duration", let d = duration, d > 0 else { return nil }
                return Double(d)
            default:
                return nil
            }
        }

        for row in work {
            let candidate = Candidate(
                setId: row["id"],
                sessionId: row["sessionId"],
                completedAt: row["completedAt"] ?? "",
                values: [:]
            )
            let weight: Double? = row["actualWeight"]
            let reps: Int? = row["actualReps"]
            let duration: Int? = row["actualDuration"]
            for kind in kinds {
                guard let v = value(of: kind, weight: weight, reps: reps, duration: duration) else { continue }
                if let current = bestValue[kind] {
                    // Holder = max value; ties → earliest completedAt, then id.
                    let earlier = candidate.completedAt < bestHolder[kind]!.completedAt
                        || (candidate.completedAt == bestHolder[kind]!.completedAt && candidate.setId < bestHolder[kind]!.setId)
                    if v > current || (v == current && earlier) {
                        bestValue[kind] = v
                        bestHolder[kind] = candidate
                    }
                } else {
                    bestValue[kind] = v
                    bestHolder[kind] = candidate
                }
            }
        }

        for kind in kinds {
            let existing = try Row.fetchOne(db, sql: """
                SELECT id, value, setId
                  FROM personal_record
                 WHERE exerciseId = ? AND kind = ? AND deletedAt IS NULL
                """, arguments: [exerciseId, kind])
            switch (existing, bestValue[kind]) {
            case (.none, .none):
                continue
            case let (.some(row), .some(v)):
                let holder = bestHolder[kind]!
                let rowValue: Double = row["value"]
                let rowSetId: String? = row["setId"]
                if rowValue != v || rowSetId != holder.setId {
                    try db.execute(sql: """
                        UPDATE personal_record
                           SET value = ?, setId = ?, sessionId = ?, achievedAt = ?, updatedAt = ?
                         WHERE id = ?
                        """, arguments: [v, holder.setId, holder.sessionId, holder.completedAt, now, row["id"] as String])
                }
            case (.none, .some(let v)):
                let holder = bestHolder[kind]!
                try db.execute(sql: """
                    INSERT INTO personal_record
                        (id, exerciseId, sessionId, setId, kind, value, achievedAt, createdAt, updatedAt, deletedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """, arguments: [
                        UUID().uuidString.lowercased(), exerciseId, holder.sessionId, holder.setId,
                        kind, v, holder.completedAt, now, now,
                    ])
            case (.some(let row), .none):
                try db.execute(sql: "UPDATE personal_record SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                               arguments: [now, now, row["id"] as String])
            }
        }
    }

    private static func clockNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}

public enum HevyImportDAOError: Error, Equatable, CustomStringConvertible {
    case unresolvedExercise(String)

    public var description: String {
        switch self {
        case .unresolvedExercise(let normalized):
            return "unresolvedExercise: \(normalized)"
        }
    }
}
