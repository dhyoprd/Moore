// contractId: SC-routines @1.0.0
// Model: Folder row — flat, cosmetic grouping for routines (#3 invariant 5).

import Foundation

/// A single row of the `folder` table. One level deep, routines-only, cosmetic —
/// zero behavioural effect (#3 / SC-routines §2c, INV-R3).
public struct Folder: Codable, Equatable, Sendable, Identifiable {
    public var id: String              // UUID v4, lowercase-hyphenated (INV-1)
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?        // tombstone (INV-3); nil while live

    public init(
        id: String,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// True when tombstoned (INV-3).
    public var isTombstoned: Bool { deletedAt != nil }
}
