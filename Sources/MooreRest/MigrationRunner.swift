// contractId: SC-rest @1.0.0
// MooreRest module migration runner (§3d). Registers migration 0007 verbatim
// from its raw .sql resource, keyed by its filename. Foundation (#19) and
// routines (#21) migrations run in their own modules' runners; this runner is
// just the rest layer's additive step.

import Foundation
import GRDB

public enum MooreRestMigrationError: Error {
    case migrationResourceMissing(String)
}

public enum MooreRestMigrations {
    public static let migrationNames: [String] = [
        "0007_rest_fields.sql",
    ]

    public static func migrate(_ writer: some DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        for name in migrationNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw MooreRestMigrationError.migrationResourceMissing(name)
            }
            let sql = try String(contentsOf: url, encoding: .utf8)
            migrator.registerMigration(name) { db in
                try db.execute(sql: sql)
            }
        }

        try migrator.migrate(writer)
    }
}
