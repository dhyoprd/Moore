// SC-foundation@1.0.0 — migrations applied in order by name.
// Migrations ship as raw .sql resources; this runner registers each file under
// its filename (its stable migration identifier) and executes the SQL verbatim.
// Identifiers: "0001_core.sql", "0002_warmup_progression.sql", "0003_import_columns.sql".

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
