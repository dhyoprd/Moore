// Ticket #43 — MooreAnalytics module migration runner (#32 canonical chain).
// Registers migration 0012 verbatim from its raw .sql resource, keyed by
// filename — same pattern as the other module runners (MooreWarmupMigrations,
// MooreSettingsMigrations). App-level integrators call this after
// MooreSettingsMigrations (0011) in the canonical chain order.
//
// INV-A1 note: SC-analytics' "never persisted" invariant governs DERIVED
// analytics (and still does — ValidationMetricsEngine recomputes everything at
// read). 0012 stores raw INPUTS only: app foreground events (an event timeline
// like completed_set) and builder-entered baseline values — source data, not
// aggregates. The frozen read surface (AnalyticsDAO/AnalyticsEngine) keeps no
// write path; the V13 read-only audit of those two files stays green.

import Foundation
import GRDB

public enum MooreAnalyticsMigrationError: Error {
    case migrationResourceMissing(String)
}

public enum MooreAnalyticsMigrations {
    public static let migrationNames: [String] = [
        "0012_validation_metrics.sql",
    ]

    public static func migrate(_ writer: some DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        for name in migrationNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw MooreAnalyticsMigrationError.migrationResourceMissing(name)
            }
            let sql = try String(contentsOf: url, encoding: .utf8)
            migrator.registerMigration(name) { db in
                try db.execute(sql: sql)
            }
        }

        try migrator.migrate(writer)
    }
}
