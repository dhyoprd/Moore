// Ticket #33 — composition root / dependency injection for the Moore iOS app.
// Boots the local-first database (GRDB in Application Support), applies the ONE
// canonical migration chain (#32) across the module bundles in order, seeds the
// built-in exercise library (SC-exercises §5), and constructs the DAOs +
// view-models the SwiftUI environment injects.
//
// Foundation-only (no SwiftUI) so it parses/verifies off-Mac — the SwiftUI layer
// in MooreApp.swift only calls AppState.boot().
//
// Note on DatabaseQueue vs DatabasePool: the frozen module DAOs (RoutineDAO,
// FolderDAO, ExerciseDAO, WorkoutSessionDAO) are typed against GRDB's
// DatabaseQueue, so the app opens a DatabaseQueue on disk. The on-disk file is
// the "local-first database" of the ticket; the seam type is the modules' call.

import Foundation
import GRDB
import MooreFoundation
import MooreExercises
import MooreRoutines
import MooreWorkout
import MooreProgression
import MooreRest
import MooreRecords
import MooreAnalytics
import MooreWarmup
import MooreSettings
import MooreImport

// MARK: - Boot errors (mapped onto SC-foundation §6 fatal-recovery copy)

public enum BootError: Error, Equatable {
    /// The database file/directory could not be created or opened.
    case storageUnavailable(String)
    /// A migration in the canonical chain failed to apply.
    case migrationFailed(String)
    /// Post-migration integrity check failed (chain incomplete).
    case chainIncomplete(missing: [String])
    /// Built-in exercise seeding failed (SC-exercises §5).
    case seedFailed(String)

    public var isMigrationFailure: Bool {
        switch self {
        case .migrationFailed, .chainIncomplete: return true
        default: return false
        }
    }
}

// MARK: - Composition root

/// Everything the app's screens need, constructed once at launch. Immutable;
/// the DAOs inside are Sendable value types over one shared DatabaseQueue. The
/// container itself is created and consumed on the main thread (not Sendable,
/// since HomeSurfaceViewModel is a non-Sendable class).
public struct AppDependencies {
    public let databasePath: String
    public let dbQueue: DatabaseQueue

    public let exerciseDAO: ExerciseDAO
    public let routineDAO: RoutineDAO
    public let folderDAO: FolderDAO
    public let sessionDAO: WorkoutSessionDAO
    public let restSettingsDAO: RestSettingsDAO
    public let settingsDAO: SettingsDAO
    public let progressionDAO: ProgressionDAO
    public let warmupDAO: WarmupDAO
    /// #36/#37 — the record book seam (live write path, re-derivation, Summary
    /// reads, and the History PR-badge probe `fetchSessionPRBadges`).
    public let personalRecordDAO: PersonalRecordDAO
    /// #37 — the strictly-derived analytics seam (read-only; INV-A1).
    public let analyticsDAO: AnalyticsDAO

    public let sessionStats: SessionStatsProvider
    public let homeSurface: HomeSurfaceViewModel
    public let materialize: Materialize
    /// #35 — progression + warm-up + stall state (drives ProgressionEngine /
    /// ProgressionDAO / WarmupRamp; all logic lives in this Foundation model).
    public let progression: ProgressionModel
    /// #39 — Hevy CSV import seam-2 (SC-import BR-015/BR-016): the one-
    /// transaction apply + PR re-derivation. Driven by ImportModel.
    public let hevyImportDAO: HevyImportDAO

    // MARK: Boot

    /// Opens (creating if needed) the Application Support database, applies the
    /// full canonical migration chain, verifies it, seeds the built-in exercise
    /// library, and wires the DAOs/view-models. Throws BootError on any failure —
    /// the app surface maps those onto the SC-foundation §6 recovery copy.
    public static func boot() throws -> AppDependencies {
        let dbURL = try databaseFileURL()
        let dbQueue: DatabaseQueue
        do {
            dbQueue = try DatabaseQueue(path: dbURL.path)
        } catch {
            throw BootError.storageUnavailable("\(error)")
        }

        do {
            try migrateFullChain(dbQueue)
            try verifyChainApplied(dbQueue)
        } catch let error as BootError {
            throw error
        } catch {
            throw BootError.migrationFailed("\(error)")
        }

        let exerciseDAO = ExerciseDAO(dbQueue: dbQueue)
        do {
            let seedURL = try MooreExercisesResources.builtinSeedURL()
            try exerciseDAO.seedBuiltInsIfNeeded(seedURL: seedURL)
        } catch {
            throw BootError.seedFailed("\(error)")
        }

        let routineDAO = RoutineDAO(dbQueue: dbQueue)
        let folderDAO = FolderDAO(dbQueue: dbQueue)
        let sessionDAO = WorkoutSessionDAO(dbQueue: dbQueue)
        let restSettingsDAO = RestSettingsDAO(dbQueue: dbQueue)
        let settingsDAO = SettingsDAO(dbQueue: dbQueue)
        let progressionDAO = ProgressionDAO(dbQueue: dbQueue)
        let warmupDAO = WarmupDAO(dbQueue: dbQueue)
        let personalRecordDAO = PersonalRecordDAO(dbQueue: dbQueue)
        // #37 — read-only analytics seam. No schema surface of its own (INV-A1);
        // it composes AnalyticsEngine over the live tables migrated above.
        let analyticsDAO = AnalyticsDAO(dbQueue: dbQueue)
        let sessionStats = SessionStatsProvider(dbQueue: dbQueue)
        let homeSurface = HomeSurfaceViewModel(
            routineDAO: routineDAO,
            folderDAO: folderDAO,
            sessionStatsProvider: sessionStats
        )
        let materialize = Materialize(dao: sessionDAO)
        let hevyImportDAO = HevyImportDAO(dbQueue: dbQueue)
        let progression = ProgressionModel(
            dbQueue: dbQueue,
            progressionDAO: progressionDAO,
            warmupDAO: warmupDAO,
            exerciseDAO: exerciseDAO,
            routineDAO: routineDAO,
            settingsDAO: settingsDAO
        )

        return AppDependencies(
            databasePath: dbURL.path,
            dbQueue: dbQueue,
            exerciseDAO: exerciseDAO,
            routineDAO: routineDAO,
            folderDAO: folderDAO,
            sessionDAO: sessionDAO,
            restSettingsDAO: restSettingsDAO,
            settingsDAO: settingsDAO,
            progressionDAO: progressionDAO,
            warmupDAO: warmupDAO,
            personalRecordDAO: personalRecordDAO,
            analyticsDAO: analyticsDAO,
            sessionStats: sessionStats,
            homeSurface: homeSurface,
            materialize: materialize,
            progression: progression,
            hevyImportDAO: hevyImportDAO
        )
    }

    // MARK: Migration chain

    /// The ONE canonical chain (#32 — MigrationRunner.canonicalChainIdentifiers),
    /// applied in order. Each module owns its own .sql files and runner; GRDB
    /// records applied identifiers in `grdb_migrations` and skips any that are
    /// already applied, so the per-module runners compose idempotently.
    public static func migrateFullChain(_ writer: some DatabaseWriter) throws {
        try MigrationRunner.migrate(writer)              // 0001–0003  MooreFoundation
        try MooreExercisesMigrations.migrate(writer)     // 0004       MooreExercises
        try MooreRoutinesMigrations.migrate(writer)      // 0005–0006  MooreRoutines
        try MooreProgressionMigrations.migrate(writer)   // 0007       MooreProgression
        try MooreRestMigrations.migrate(writer)          // 0008       MooreRest
        try MooreRecordsMigrations.migrate(writer)       // 0009       MooreRecords
        try MooreWarmupMigrations.migrate(writer)        // 0010       MooreWarmup
        try MooreSettingsMigrations.migrate(writer)      // 0011       MooreSettings
    }

    /// Asserts every identifier of the canonical chain is present in
    /// `grdb_migrations` — the first-boot acceptance ("applies the full migration
    /// chain") checked explicitly, not assumed.
    public static func verifyChainApplied(_ writer: some DatabaseWriter) throws {
        let applied: Set<String> = try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        }
        let expected = MigrationRunner.canonicalChainIdentifiers
        let missing = expected.filter { !applied.contains($0) }
        guard missing.isEmpty else {
            throw BootError.chainIncomplete(missing: missing)
        }
    }

    // MARK: Paths

    /// `<Application Support>/Moore/moore.sqlite` — created on first boot.
    /// On iOS this resolves inside the app container (Library/Application Support).
    public static func databaseFileURL() throws -> URL {
        let base = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("Moore", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BootError.storageUnavailable("cannot create \(directory.path): \(error)")
        }
        return directory.appendingPathComponent("moore.sqlite")
    }
}
