// SC-foundation@1.0.0 — migrations applied in order by name.
// Migrations ship as raw .sql resources; this runner registers each file under
// its filename (its stable migration identifier) and executes the SQL verbatim.
// Identifiers: "0001_core.sql", "0002_warmup_progression.sql", "0003_import_columns.sql".
//
// #32: `canonicalChainIdentifiers` documents the ONE reconciled chain order
// (unique numbers, no collisions) that app-level integrators register across
// the module bundles. Each module owns its own files; the identifiers are the
// stable GRDB migration keys.

import Foundation
import GRDB

public enum MigrationRunnerError: Error {
    case migrationResourceMissing(String)
}

public enum MigrationRunner {
    public static let migrationNames: [String] = [
        "0001_core.sql",
        "0002_warmup_progression.sql",
        "0003_import_columns.sql",
    ]

    /// The ONE canonical chain (#32), in apply order, across all module bundles:
    /// MooreFoundation (0001-0003), MooreExercises (0004, rewritten over the real
    /// 0001 shape), MooreRoutines (0005-0006), MooreProgression (0007),
    /// MooreRest (0008), MooreRecords (0009), MooreWarmup (0010), MooreSettings (0011).
    public static let canonicalChainIdentifiers: [String] = [
        "0001_core.sql",
        "0002_warmup_progression.sql",
        "0003_import_columns.sql",
        "0004_exercise_library.sql",
        "0005_routines_folders.sql",
        "0006_routines_session_link.sql",
        "0007_progression_full.sql",
        "0008_rest_fields.sql",
        "0009_personal_records.sql",
        "0010_warmup_per_exercise_toggle.sql",
        "0011_body_metrics.sql",
    ]

    public static func migrate(_ writer: some DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        for name in migrationNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw MigrationRunnerError.migrationResourceMissing(name)
            }
            let sql = try String(contentsOf: url, encoding: .utf8)
            migrator.registerMigration(name) { db in
                try db.execute(sql: sql)
            }
        }

        try migrator.migrate(writer)
    }
}
