// contractId: SC-routines @1.0.0
// GRDB-backed DAO for `folder`. Soft-delete unfiles (never cascades to) contained
// routines per BR-003. Tombstone rule: reads filter `deletedAt IS NULL` by default;
// no `DELETE FROM` anywhere at this layer.

import Foundation
import GRDB

public enum FolderError: Error, Equatable {
    case notFound(String)
}

/// Storage shape for `folder` (created by #19's 0001; guarded by 0005).
struct FolderRowStorage: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "folder"
    var id: String
    var name: String
    var createdAt: String              // ISO-8601 UTC
    var updatedAt: String
    var deletedAt: String?
}

private let folderISO = ISO8601DateFormatter()

private func toDomain(_ f: FolderRowStorage) -> Folder {
    Folder(
        id: f.id,
        name: f.name,
        createdAt: folderISO.date(from: f.createdAt) ?? Date.distantPast,
        updatedAt: folderISO.date(from: f.updatedAt) ?? Date.distantPast,
        deletedAt: f.deletedAt.flatMap { folderISO.date(from: $0) }
    )
}

public struct FolderDAO: Sendable {
    public let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: Create

    @discardableResult
    public func create(name: String) throws -> Folder {
        let now = Date()
        let folder = Folder(
            id: UUID().uuidString.lowercased(),
            name: name,
            createdAt: now, updatedAt: now, deletedAt: nil
        )
        try dbQueue.write { db in
            try FolderRowStorage(
                id: folder.id, name: folder.name,
                createdAt: folderISO.string(from: now),
                updatedAt: folderISO.string(from: now),
                deletedAt: nil
            ).insert(db)
        }
        return folder
    }

    // MARK: Read

    /// Live (non-tombstoned) folders, name asc — the Home grouping list.
    public func fetchAll() throws -> [Folder] {
        try dbQueue.read { db in
            try FolderRowStorage
                .filter(Column("deletedAt") == nil)
                .order(Column("name"))
                .fetchAll(db)
        }
        .map(toDomain)
    }

    public func fetch(id: String) throws -> Folder? {
        try dbQueue.read { db in
            try FolderRowStorage
                .filter(Column("id") == id && Column("deletedAt") == nil)
                .fetchOne(db)
        }
        .map(toDomain)
    }

    /// Raw fetch incl. tombstoned (INV-3).
    public func fetchIncludingTombstoned(id: String) throws -> Folder? {
        try dbQueue.read { db in
            try FolderRowStorage.fetchOne(db, key: id)
        }
        .map(toDomain)
    }

    // MARK: Rename

    /// Renames a folder (§2c). Does not touch any contained routine's `updatedAt`
    /// (the rename is a folder-only mutation; contents are untouched edge case §7).
    @discardableResult
    public func rename(id: String, to name: String) throws -> Folder {
        let nowStr = folderISO.string(from: Date())
        return try dbQueue.write { db in
            guard var row = try FolderRowStorage.fetchOne(db, key: id),
                  row.deletedAt == nil else {
                throw FolderError.notFound(id)
            }
            row.name = name
            row.updatedAt = nowStr
            try row.update(db)
            return toDomain(row)
        }
    }

    // MARK: Delete (BR-003 / V5)

    /// Soft-deletes a folder AND unfiles every routine it contains, in one transaction.
    /// Per BR-003: contained routines' `folderId` becomes NULL (they survive as
    /// top-level Unfiled); no routine is tombstoned, moved, or reordered. Idempotent.
    public func tombstone(id: String) throws {
        let nowStr = folderISO.string(from: Date())
        try dbQueue.write { db in
            guard var row = try FolderRowStorage.fetchOne(db, key: id) else {
                throw FolderError.notFound(id)
            }
            guard row.deletedAt == nil else { return }
            row.deletedAt = nowStr
            row.updatedAt = nowStr
            try row.update(db)

            // Unfile contents — do NOT cascade the tombstone (BR-003 / INV-R3).
            try db.execute(sql: """
                UPDATE routine SET folderId = NULL, updatedAt = ?
                WHERE folderId = ? AND deletedAt IS NULL
                """, arguments: [nowStr, id])
        }
    }
}
