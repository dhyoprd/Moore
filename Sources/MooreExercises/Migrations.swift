// contractId: SC-exercises @1.0.0
// Module-level migration runner + resource accessors (#32 canonical chain).
// Registers migration 0004 verbatim from its raw .sql resource, keyed by its
// filename — the same pattern as MooreFoundation.MigrationRunner,
// MooreRestMigrations, and MooreSettingsMigrations. App-level integrators call
// this after MigrationRunner (0001–0003) in the canonical chain order.
// Also exposes the built-in seed JSON URL (SC-exercises §5 seeding) so the app's
// composition root can run ExerciseDAO.seedBuiltInsIfNeeded without reaching
// into this module's Bundle.module (which is internal).

import Foundation
import GRDB

public enum MooreExercisesMigrationError: Error {
    case migrationResourceMissing(String)
}

public enum MooreExercisesMigrations {
    public static let migrationNames: [String] = [
        "0004_exercise_library.sql",
    ]

    public static func migrate(_ writer: some DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        for name in migrationNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw MooreExercisesMigrationError.migrationResourceMissing(name)
            }
            let sql = try String(contentsOf: url, encoding: .utf8)
            migrator.registerMigration(name) { db in
                try db.execute(sql: sql)
            }
        }

        try migrator.migrate(writer)
    }
}

/// Public resource seam for the app's composition root.
public enum MooreExercisesResources {
    /// This module's resource bundle (public wrapper over the internal Bundle.module).
    public static var bundle: Bundle { Bundle.module }

    /// URL of `builtin-library.json` (SC-exercises §5 seed). Robust against SPM's
    /// resource layout (flattened vs. kept under `Seed/`): direct lookups first,
    /// then a recursive scan of the bundle as a last resort.
    public static func builtinSeedURL() throws -> URL {
        if let url = bundle.url(forResource: "builtin-library", withExtension: "json") {
            return url
        }
        if let url = bundle.url(forResource: "builtin-library", withExtension: "json", subdirectory: "Seed") {
            return url
        }
        if let base = bundle.resourceURL,
           let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == "builtin-library.json" {
                return url
            }
        }
        throw ExerciseLibraryError.malformedSeed("builtin-library.json not found in MooreExercises resource bundle")
    }
}
