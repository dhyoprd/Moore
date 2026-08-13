// contractId: SC-progression @1.0.0
// Module-level migration runner (#32 canonical chain). Registers migration 0007
// verbatim from its raw .sql resource, keyed by filename — same pattern as the
// other module runners. App-level integrators call this after
// MooreRoutinesMigrations (0005–0006) in the canonical chain order.

import Foundation
import GRDB

public enum MooreProgressionMigrationError: Error {
    case migrationResourceMissing(String)
}

public enum MooreProgressionMigrations {
    public static let migrationNames: [String] = [
        "0007_progression_full.sql",
    ]

    public static func migrate(_ writer: some DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        for name in migrationNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw MooreProgressionMigrationError.migrationResourceMissing(name)
            }
            let sql = try String(contentsOf: url, encoding: .utf8)
            migrator.registerMigration(name) { db in
                try db.execute(sql: sql)
            }
        }

        try migrator.migrate(writer)
    }
}
