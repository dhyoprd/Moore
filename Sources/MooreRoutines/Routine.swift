// contractId: SC-routines @1.0.0
// Model: Routine row + PlannedSet row + Routine lifecycle + editor draft structs.
// Platform-agnostic. No SwiftUI, no GRDB imports — persistence wiring lives in
// RoutineDAO.swift; this file stays a pure data contract readable by the Android port.

import Foundation

/// Warm-up vs work classification (SC-foundation INV-6). Nil reads coalesce to `.work`.
public enum SetClass: String, Codable, Sendable {
    case warmup
    case work
}

/// Routine lifecycle (SC-routines §2a). Derived from the persisted row, never stored:
/// a row with `deletedAt == nil` is `draft` until its first session start flips it to
/// `active`; `deletedAt != nil` is `tombstoned`. Persisted columns carry no state field —
/// the state is a read-time projection of `deletedAt` + "has any session started from me".
public enum RoutineLifecycle: String, Codable, Sendable {
    case draft
    case active
    case tombstoned
}

/// A single row of the `routine` table (in memory).
public struct Routine: Codable, Equatable, Sendable, Identifiable {
    public var id: String              // UUID v4, lowercase-hyphenated (INV-1)
    public var folderId: String?       // NULL = unfiled; 0..1 folder, cosmetic (INV-R3)
    public var name: String
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?        // tombstone (INV-3); nil while live

    public init(
        id: String,
        folderId: String? = nil,
        name: String,
        sortOrder: Int = 0,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.folderId = folderId
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Lifecycle (§2a): `tombstoned` if deleted, `draft` if never started, else `active`.
    /// `hasSession` = whether any session references this routine (workout_session.routineId).
    public func lifecycle(hasSession: Bool) -> RoutineLifecycle {
        if deletedAt != nil { return .tombstoned }
        return hasSession ? .active : .draft
    }

    /// True when tombstoned (INV-3). Lifecycle `tombstoned` ⇔ `deletedAt != nil`.
    public var isTombstoned: Bool { deletedAt != nil }
}

/// One intended set inside a routine (SC-routines §3b). Snapshot source for a
/// session's `plannedX` columns at materialisation (§2b / INV-R5) — the session
/// copies these values and never re-reads them.
public struct PlannedSet: Codable, Equatable, Sendable, Identifiable {
    public var id: String              // UUID v4 (INV-1)
    public var routineId: String
    public var exerciseId: String
    public var sortOrder: Int
    public var plannedWeight: Double?
    public var plannedReps: Int?
    public var plannedDuration: Int?   // seconds
    public var setClass: SetClass?     // INV-6: NULL from pre-0002 rows; readers coalesce → .work
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String,
        routineId: String,
        exerciseId: String,
        sortOrder: Int,
        plannedWeight: Double? = nil,
        plannedReps: Int? = nil,
        plannedDuration: Int? = nil,
        setClass: SetClass? = nil,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.routineId = routineId
        self.exerciseId = exerciseId
        self.sortOrder = sortOrder
        self.plannedWeight = plannedWeight
        self.plannedReps = plannedReps
        self.plannedDuration = plannedDuration
        self.setClass = setClass
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

// MARK: - Editor draft structs (§2a, V2)

/// A set row as held in the routine editor's in-progress buffer. Distinct from the
/// persisted `PlannedSet`: no timestamp/identity bookkeeping — only what the user edits.
/// `applyChanges()` maps these back onto `PlannedSet` rows.
public struct EditableSetDraft: Codable, Equatable, Sendable, Identifiable {
    public var id: String              // pre-generated UUID; becomes PlannedSet.id on save
    public var exerciseId: String
    public var plannedWeight: Double?
    public var plannedReps: Int?
    public var plannedDuration: Int?   // seconds
    public var setClass: SetClass

    public init(
        id: String,
        exerciseId: String,
        plannedWeight: Double? = nil,
        plannedReps: Int? = nil,
        plannedDuration: Int? = nil,
        setClass: SetClass = .work
    ) {
        self.id = id
        self.exerciseId = exerciseId
        self.plannedWeight = plannedWeight
        self.plannedReps = plannedReps
        self.plannedDuration = plannedDuration
        self.setClass = setClass
    }
}
