// SC-foundation@1.0.0 — §3 Data Schema, typed row models.
// One Codable struct per entity; FetchableRecord/PersistableRecord wiring lives
// in DAO.swift so this file stays a pure data contract readable by the Android port.

import Foundation

public enum ExerciseType: String, Codable { case strength, cardio, custom = "custom" }
public enum SetClass: String, Codable { case warmup, work }
public enum SetStatus: String, Codable { case planned, completed, failed, dropped }
public enum PRKind: String, Codable { case weight, volume, rep }
public enum MetricKind: String, Codable { case bodyWeight, bodyFat, weight }
public enum MetricUnit: String, Codable { case kg, lb, pct }
public enum ProgressionSchemeKind: String, Codable { case linear, double = "double", percentage }

public struct Folder: Codable, Equatable {
    public var id: String
    public var name: String
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?
}

public struct Exercise: Codable, Equatable {
    public var id: String
    public var name: String
    public var exerciseType: ExerciseType
    public var equipmentSlug: String?
    public var primaryMuscleId: String?
    public var secondaryMuscleIdsJson: String?
    public var instructions: String?
    public var isCustom: Int
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?
}

public struct Routine: Codable, Equatable {
    public var id: String
    public var folderId: String?
    public var name: String
    public var sortOrder: Int
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?
}

public struct PlannedSet: Codable, Equatable {
    public var id: String
    public var routineId: String
    public var exerciseId: String
    public var sortOrder: Int
    public var plannedWeight: Double?
    public var plannedReps: Int?
    public var plannedDuration: Int?
    public var setClass: SetClass?   // INV-6: NULL from pre-0002 rows; readers coalesce to .work
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?
}

public struct WorkoutSession: Codable, Equatable {
    public var id: String
    public var name: String?
    public var notes: String?
    public var startedAt: String
    public var endedAt: String?
    public var importSource: String?
    public var importKey: String?
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?
}

public struct CompletedSet: Codable, Equatable {
    public var id: String
    public var sessionId: String
    public var exerciseId: String
    public var sortOrder: Int
    public var plannedWeight: Double?
    public var plannedReps: Int?
    public var plannedDuration: Int?
    public var actualWeight: Double?
    public var actualReps: Int?
    public var actualDuration: Int?
    public var status: SetStatus
    public var setClass: SetClass?   // INV-6
    public var completedAt: String?
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?
}

public struct PersonalRecord: Codable, Equatable {
    public var id: String
    public var exerciseId: String
    public var setId: String?
    public var kind: PRKind
    public var value: Double
    public var achievedAt: String
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?
}

public struct BodyMetric: Codable, Equatable {
    public var id: String
    public var kind: MetricKind
    public var value: Double
    public var unit: MetricUnit
    public var recordedAt: String
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?
}

public struct ProgressionScheme: Codable, Equatable {
    public var id: String
    public var routineId: String
    public var exerciseId: String
    public var scheme: ProgressionSchemeKind
    public var incrementValue: Double?
    public var doubleProgressionMinReps: Int?
    public var doubleProgressionMaxReps: Int?
    public var warmupEnabled: Int
    public var stallCount: Int
    public var stallMuted: Int
    public var lastDeloadSessionId: String?
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?
}
