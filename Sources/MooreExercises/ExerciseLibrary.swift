// contractId: SC-exercises @1.0.0
// In-memory index over the seed JSON + on-top-of-DB customs.
// Pure logic layer: no GRDB, no UI. The DAO (ExerciseDAO.swift) sits between
// this and SQLite. The in-memory index exists so pickers can autocomplete
// with zero IO on the hot path; the DAO is authoritative.

import Foundation

public struct BuiltinLibrarySeed: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var exercises: [BuiltinExercise]
}

public struct BuiltinExercise: Codable, Equatable, Sendable {
    public var id: String            // stable slug, e.g. "barbell-bench-press"
    public var name: String
    public var category: ExerciseCategory
    public var defaultMetric: DefaultMetric
    public var equipment: ExerciseEquipment
}

public enum ExerciseLibraryError: Error, Equatable, CustomStringConvertible {
    case malformedSeed(String)
    case duplicateNormalizedName(String)   // severe: two rows share a BR-001 key
    case immutableFieldMutation(ExerciseID)
    case notFound(ExerciseID)

    public typealias ExerciseID = String

    public var description: String {
        switch self {
        case .malformedSeed(let msg):        return "malformedSeed: \(msg)"
        case .duplicateNormalizedName(let n):return "duplicateNormalizedName: \(n)"
        case .immutableFieldMutation(let id):return "immutableFieldMutation: \(id)"
        case .notFound(let id):             return "notFound: \(id)"
        }
    }
}

/// Read-only in-memory index over exercises. Built once at launch (SC-exercises §5 seeding).
public struct ExerciseLibrary: Sendable {
    /// Keyed by BR-001 normalized name. Index-based lookup for BR-003 substring search.
    private let rowsById: [String: Exercise]
    private let normalizedIndex: [(normalized: String, id: String)]

    public init(exercises: [Exercise]) throws {
        var byId: [String: Exercise] = [:]
        var idx: [(String, String)] = []
        var seenNormalized: Set<String> = []
        for e in exercises where e.deletedAt == nil {
            if seenNormalized.contains(e.nameNormalized) && !e.isCustom {
                // Two built-ins with the same normalized name is a seed-build bug.
                throw ExerciseLibraryError.duplicateNormalizedName(e.nameNormalized)
            }
            seenNormalized.insert(e.nameNormalized)
            byId[e.id] = e
            idx.append((e.nameNormalized, e.id))
        }
        self.rowsById = byId
        self.normalizedIndex = idx
    }

    /// Decode the seed JSON from the bundle. Throws on schema mismatch.
    public static func decodeBuiltinSeed(jsonData: Data) throws -> BuiltinLibrarySeed {
        let decoder = JSONDecoder()
        let seed = try decoder.decode(BuiltinLibrarySeed.self, from: jsonData)
        guard seed.schemaVersion == 1 else {
            throw ExerciseLibraryError.malformedSeed("unsupported schemaVersion \(seed.schemaVersion)")
        }
        return seed
    }

    /// Build an initial `Exercise` from a seed entry. `createdAt`/`updatedAt` are fixed
    /// by the caller (typically to the first-launch timestamp; stable across reseeds
    /// because the row is INSERT-OR-IGNOREd — a reseed never writes on conflict).
    public static func row(from seed: BuiltinExercise, createdAt: Date, updatedAt: Date) -> Exercise {
        Exercise(
            id: seed.id,
            isCustom: false,
            name: seed.name,
            nameNormalized: NameNormalization.normalize(seed.name),
            category: seed.category,
            defaultMetric: seed.defaultMetric,
            equipment: seed.equipment,
            defaultRestSec: nil,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// BR-003: case-insensitive substring against `nameNormalized`. Caller splits the
    /// pre-filtered tombstones. Results sorted per §5: exact hit first, built-ins first,
    /// then alphabetical.
    public func search(query: String, category: ExerciseCategory? = nil, excludeIds: Set<String> = []) -> [Exercise] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = NameNormalization.normalize(trimmed)
        // Empty query => caller's "idle" path; do not search, return sorted browse list.
        if normalizedQuery.isEmpty {
            return rowsById.values
                .filter { $0.deletedAt == nil && !excludeIds.contains($0.id) }
                .filter { category == nil || $0.category == category }
                .sorted(by: Self.sortRule)
        }
        var matches: [Exercise] = []
        for (norm, id) in normalizedIndex {
            guard !excludeIds.contains(id) else { continue }
            guard let row = rowsById[id], row.deletedAt == nil else { continue }
            if let c = category, row.category != c { continue }
            if norm.contains(normalizedQuery) {
                matches.append(row)
            }
        }
        // Exact normalized-name hit first.
        matches.sort { a, b in
            let aExact = a.nameNormalized == normalizedQuery
            let bExact = b.nameNormalized == normalizedQuery
            if aExact != bExact { return aExact }
            return Self.sortRule(a, b)
        }
        return matches
    }

    public func getById(_ id: String) -> Exercise? { rowsById[id] }

    public static func sortRule(_ a: Exercise, _ b: Exercise) -> Bool {
        // built-ins first, then alphabetical by display name (stable: secondary by id)
        if a.isCustom != b.isCustom { return !a.isCustom }
        if a.name != b.name { return a.name < b.name }
        return a.id < b.id
    }
}
