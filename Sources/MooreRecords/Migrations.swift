// contractId: SC-prs @1.0.0
// Module-level migration runner (#32 canonical chain). Registers migration 0009
// verbatim from its raw .sql resource, keyed by filename — same pattern as the
// other module runners. App-level integrators call this after
// MooreRestMigrations (0008) in the canonical chain order.

import Foundation
import GRDB

public enum MooreRecordsMigrationError: Error {
    case migrationResourceMissing(String)
}

public enum MooreRecordsMigrations {
    public static let migrationNames: [String] = [
        "0009_personal_records.sql",
    ]

    public static func migrate(_ writer: some DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        for name in migrationNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw MooreRecordsMigrationError.migrationResourceMissing(name)
            }
            let sql = try String(contentsOf: url, encoding: .utf8)
            migrator.registerMigration(name) { db in
                try db.execute(sql: sql)
            }
        }

        try migrator.migrate(writer)
    }
}
