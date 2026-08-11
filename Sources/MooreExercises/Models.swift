// contractId: SC-exercises @1.0.0
// Models: Exercise row + ExerciseCategory + Picker state surface.
// Platform-agnostic. No SwiftUI, no GRDB imports — persistence types are
// mapped to/from these plain structs by the DAO layer.

import Foundation

/// The categories the picker browse view renders, in display order.
/// (SC-exercises §3b; §6 gives the UI copy keys.)
public enum ExerciseCategory: String, CaseIterable, Codable, Sendable {
    case chest
    case back
    case shoulders
    case biceps
    case triceps
    case forearms
    case core
    case quads
    case hamstrings
    case glutes
    case calves
    case fullBody
    case cardio
    case other

    /// Muscle-split bucket for #27's analytics (upper/lower split).
    /// This is a READ-TIME derivation, never persisted. SC-exercises §3b.
    public var splitBucket: SplitBucket {
        switch self {
        case .chest, .back, .shoulders, .biceps, .triceps, .forearms, .cardio:
            return .upper
        case .quads, .hamstrings, .glutes, .calves:
            return .lower
        case .core, .fullBody, .other:
            return .other
        }
    }
}

public enum SplitBucket: String, Codable, Sendable {
    case upper, lower, other
}

public enum DefaultMetric: String, Codable, Sendable {
    case reps
    case duration
}

public enum ExerciseEquipment: String, CaseIterable, Codable, Sendable {
    case barbell, dumbbell, cable, machine, bodyweight, smith, plate, band
    case kettlebell, ezBar, trapBar, medicineBall, sled, other
}

/// A single row of the `exercise` table (in memory). Never mutate a built-in.
public struct Exercise: Codable, Equatable, Sendable, Identifiable {
    public var id: String            // UUID for customs; stable slug for built-ins
    public var isCustom: Bool
    public var name: String
    public var nameNormalized: String // BR-001 materialized
    public var category: ExerciseCategory
    public var defaultMetric: DefaultMetric
    public var equipment: ExerciseEquipment
    public var defaultRestSec: Int?   // BR-009 slot
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?       // tombstone

    public init(
        id: String,
        isCustom: Bool,
        name: String,
        nameNormalized: String,
        category: ExerciseCategory,
        defaultMetric: DefaultMetric,
        equipment: ExerciseEquipment,
        defaultRestSec: Int? = nil,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.isCustom = isCustom
        self.name = name
        self.nameNormalized = nameNormalized
        self.category = category
        self.defaultMetric = defaultMetric
        self.equipment = equipment
        self.defaultRestSec = defaultRestSec
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// True when tombstoned. Convenience for reads that must not depend on `deletedAt`.
    public var isTombstoned: Bool { deletedAt != nil }
}

/// The picker's state machine (SC-exercises §2b). Pure value-type so SwiftUI /
/// Compose can bind to it; the *transitions* live in `PickerViewModel`.
public enum PickerState: Equatable, Sendable {
    /// Search field empty; browse-by-category visible.
    case idle
    /// Non-empty query, non-empty result set.
    case searching(query: String)
    /// Non-empty query, empty result set.
    case noResults(query: String)
    /// Inline create form open. `seedName` = verbatim user text from search field.
    case creating(seedName: String)
    /// Just-created; auto-selects on the same tick.
    case created(exerciseId: String)
    /// Terminal; dismissal follows.
    case selected(exerciseId: String)
}

/// Result emitted by the picker to its parent. Exactly one per presentation.
public enum PickerResult: Equatable, Sendable {
    case selected(exerciseId: String)
    case createdCustom(exerciseId: String, name: String)
    case cancelled
}
