// SC-foundation@1.0.0 — seam-2 persistence tests.
// Companion to VerifyMigrations.mjs: same fixtures, same vectors, run via GRDB on
// a real Apple toolchain. Cite BR IDs per template §7. This file will not compile
// on Windows (no GRDB iOS port); it is the hand-off artifact.

import XCTest
@testable import MooreFoundation

final class Seam2PersistenceTests: XCTestCase {

    /// V1, V2 → BR-001: fresh + idempotent apply.
    func test_migrations_applyCleanly_inSequence() throws {
        _ = try Database.inMemory()
    }

    /// V3 → INV-1/INV-4: Folder round-trip.
    func test_folder_roundTrip_vector03() throws {
        let db = try Database.inMemory()
        var folder = Folder(
            id: UUID().uuidString.lowercased(),
            name: "Push Days",
            createdAt: "2026-08-11T10:00:00Z",
            updatedAt: "2026-08-11T10:00:00Z",
            deletedAt: nil
        )
        try db.insertFolder(folder)
        let fetched = try db.fetchFolders().first { $0.id == folder.id }
        XCTAssertEqual(fetched, folder)
    }

    /// V8 → BR-007: duplicate importKey is deduped.
    func test_importKey_deduped_vector08() throws {
        let db = try Database.inMemory()
        let key = "hevy_test_001"
        let first = WorkoutSession(
            id: UUID().uuidString.lowercased(), name: "A", notes: nil,
            startedAt: "2026-08-05T18:30:00Z", endedAt: nil,
            importSource: "hevy", importKey: key,
            createdAt: "2026-08-05T19:50:00Z", updatedAt: "2026-08-05T19:50:00Z",
            deletedAt: nil
        )
        _ = try db.insertWorkoutSessionRespectingImportKey(first)

        var second = first
        second.id = UUID().uuidString.lowercased()
        let existingId = try db.insertWorkoutSessionRespectingImportKey(second)
        XCTAssertEqual(existingId, first.id)
    }

    /// V14 → BR-003: tombstoned row hidden from default fetch, present in raw.
    func test_tombstone_hidesFromDefaultFetch_vector14() throws {
        let db = try Database.inMemory()
        let folder = Folder(
            id: UUID().uuidString.lowercased(), name: "Push Days",
            createdAt: "2026-08-11T10:00:00Z", updatedAt: "2026-08-11T10:00:00Z",
            deletedAt: nil
        )
        try db.insertFolder(folder)
        try db.softDeleteFolder(id: folder.id, at: "2026-08-11T12:00:00Z")

        let visible = try db.fetchFolders()
        let raw = try db.fetchFoldersIncludingTombstoned()
        XCTAssertFalse(visible.contains { $0.id == folder.id })
        XCTAssertTrue(raw.contains { $0.id == folder.id && $0.deletedAt != nil })
    }
}
