// contractId: SC-routines @1.0.0
// Module-level migration runner (#32 canonical chain). Registers migrations
// 0005–0006 verbatim from their raw .sql resources, keyed by filename — the
// same pattern as MooreFoundation.MigrationRunner / MooreRestMigrations /
// MooreSettingsMigrations. App-level integrators call this after
// MooreExercisesMigrations (0004) in the canonical chain order.

import Foundation
import GRDB

public enum MooreRoutinesMigrationError: Error {
    case migrationResourceMissing(String)
}

public enum MooreRoutinesMigrations {
    public static let migrationNames: [String] = [
        "0005_routines_folders.sql",
        "0006_routines_session_link.sql",
    ]

    public static func migrate(_ writer: some DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        for name in migrationNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw MooreRoutinesMigrationError.migrationResourceMissing(name)
            }
            let sql = try String(contentsOf: url, encoding: .utf8)
            migrator.registerMigration(name) { db in
                try db.execute(sql: sql)
            }
        }

        try migrator.migrate(writer)
    }
}
