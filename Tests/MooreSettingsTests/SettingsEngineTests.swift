// contractId: SC-settings @1.0.0
// Host-runnable mirror checks for SettingsEngine (seam-1). The platform-free
// authority is Tests/MooreSettingsTests/VerifySettings.mjs + Fixtures/*.json;
// these XCTest cases pin the same vectors so Swift/JS drift fails loudly on an
// iOS/macOS host. Pure engine only — no GRDB, no filesystem.

import XCTest
@testable import MooreSettings

final class SettingsEngineTests: XCTestCase {

    // MARK: BR-002 — conversion math at the frozen 2.20462 ratio

    func testKgToLbRatio() {
        XCTAssertEqual(SettingsEngine.kgToLb(100), 220.462, accuracy: 1e-9)
        XCTAssertEqual(SettingsEngine.lbToKg(220.462), 100, accuracy: 1e-9)
        XCTAssertEqual(SettingsEngine.kgToLb(0), 0, accuracy: 1e-9)
    }

    func testDisplayRoundingIsOneDecimalHalfAwayFromZero() {
        XCTAssertEqual(SettingsEngine.roundDisplay(220.462), 220.5)
        XCTAssertEqual(SettingsEngine.roundDisplay(0.25), 0.3)
        XCTAssertEqual(SettingsEngine.roundStorage(81.6466), 81.65)
    }

    func testDisplayStrings() {
        XCTAssertEqual(SettingsEngine.displayString(rawKg: 100, unit: .kg), "100.0 kg")
        XCTAssertEqual(SettingsEngine.displayString(rawKg: 100, unit: .lb), "220.5 lb")
        XCTAssertEqual(SettingsEngine.displayString(rawKg: 81.65, unit: .lb), "180.0 lb")
        XCTAssertEqual(SettingsEngine.displayString(rawKg: 81.65, unit: .kg), "81.7 kg")
    }

    // MARK: BR-003 — entry respect stores canonical kg at 2dp

    func testEntryToStorage() {
        XCTAssertEqual(SettingsEngine.entryToStorage(180, unit: .lb), 81.65)
        XCTAssertEqual(SettingsEngine.entryToStorage(135, unit: .lb), 61.24)
        XCTAssertEqual(SettingsEngine.entryToStorage(81.65, unit: .kg), 81.65)
    }

    // MARK: BR-004 — body-metric display converts weight units, pct passes through

    func testDisplayBodyMetric() {
        XCTAssertEqual(SettingsEngine.displayBodyMetric(value: 82.4, rowUnit: "kg", target: .lb), 181.7)
        XCTAssertEqual(SettingsEngine.displayBodyMetric(value: 82.4, rowUnit: "kg", target: .kg), 82.4)
        XCTAssertEqual(SettingsEngine.displayBodyMetric(value: 15.5, rowUnit: "pct", target: .lb), 15.5)
        XCTAssertEqual(SettingsEngine.displayBodyMetric(value: 84, rowUnit: "cm", target: .kg), 84)
    }

    // MARK: BR-008/BR-009 — export manifest naming + completeness flags

    func testBackupFileName() {
        XCTAssertEqual(
            SettingsEngine.backupFileName(exportedAt: "2026-08-13T09:30:00Z"),
            "moore-2026-08-13T09-30-00Z.moore-backup"
        )
    }

    func testBuildExportManifestListsAllTenCoreTablesEvenWhenEmpty() {
        let manifest = SettingsEngine.buildExportManifest(tableStats: [], exportedAt: "2026-08-13T09:30:00Z")
        XCTAssertEqual(manifest.tables.map(\.table), SettingsEngine.coreTableNames)
        XCTAssertEqual(manifest.tables.count, 10)
        XCTAssertTrue(manifest.includesTombstones)
        XCTAssertTrue(manifest.includesPlannedColumns)
        XCTAssertEqual(manifest.format, "sqlite-file-copy")
        XCTAssertTrue(manifest.tables.allSatisfy { $0.rowCount == 0 && $0.tombstoneCount == 0 })
    }

    func testBuildExportManifestKeepsTombstoneCounts() {
        let stats: [SettingsEngine.TableStats] = [
            TableStats(table: "exercise", rowCount: 2, tombstoneCount: 1),
            TableStats(table: "completed_set", rowCount: 3, tombstoneCount: 1),
        ]
        let manifest = SettingsEngine.buildExportManifest(tableStats: stats, exportedAt: "2026-08-13T09:30:00Z")
        let exercise = manifest.tables.first { $0.table == "exercise" }
        XCTAssertEqual(exercise?.rowCount, 2)
        XCTAssertEqual(exercise?.tombstoneCount, 1)
    }

    // MARK: BR-010 — tombstone listing: custom only, deletedAt DESC

    func testTombstonedCustomExercisesFilterAndSort() {
        let rows: [SettingsEngine.ExerciseTombstoneRow] = [
            ExerciseTombstoneRow(id: "a", name: "Built-in", isCustom: 0, deletedAt: "2026-08-12T09:00:00Z"),
            ExerciseTombstoneRow(id: "b", name: "Live Custom", isCustom: 1, deletedAt: nil),
            ExerciseTombstoneRow(id: "c", name: "Old Custom A", isCustom: 1, deletedAt: "2026-08-10T10:00:00Z"),
            ExerciseTombstoneRow(id: "d", name: "Old Custom B", isCustom: 1, deletedAt: "2026-08-12T11:00:00Z"),
        ]
        let listed = SettingsEngine.tombstonedCustomExercises(from: rows)
        XCTAssertEqual(listed.map(\.id), ["d", "c"])
    }

    // MARK: BR-011/BR-012 — dormant surfaces

    func testCloudSyncPermanentlyGreyed() {
        XCTAssertFalse(SettingsEngine.cloudSyncStatus.enabled)
        XCTAssertTrue(SettingsEngine.cloudSyncStatus.greyed)
        XCTAssertEqual(SettingsEngine.cloudSyncStatus.copyKey, "settings.cloudSync.coming")
        XCTAssertEqual(SettingsEngine.cloudSyncStatus.infoIssue, "#4")
        XCTAssertEqual(
            SettingsEngine.settingsCopy["settings.cloudSync.coming"],
            "Coming after self-validation gate"
        )
    }

    func testHevyImportStubBlockedByTicket30() {
        XCTAssertFalse(SettingsEngine.hevyImportEntry.enabled)
        XCTAssertEqual(SettingsEngine.hevyImportEntry.blockedByTicket, "#30")
        XCTAssertEqual(SettingsEngine.hevyImportEntry.copyKey, "settings.dataSync.importHevy")
    }

    // MARK: BR-006 — body-metric validation gate

    func testBodyMetricValidation() {
        XCTAssertNil(SettingsEngine.validateBodyMetric(kind: "bodyWeight", label: nil, value: 82.4, unit: "kg"))
        XCTAssertNil(SettingsEngine.validateBodyMetric(kind: "measurement", label: "Waist", value: 84, unit: "cm"))
        XCTAssertEqual(
            SettingsEngine.validateBodyMetric(kind: "boneDensity", label: nil, value: 1, unit: "x"),
            .invalidKind("boneDensity")
        )
        XCTAssertEqual(
            SettingsEngine.validateBodyMetric(kind: "measurement", label: nil, value: 84, unit: "cm"),
            .measurementRequiresLabel
        )
        XCTAssertEqual(
            SettingsEngine.validateBodyMetric(kind: "bodyFat", label: nil, value: 15, unit: "kg"),
            .invalidUnit(kind: "bodyFat", unit: "kg")
        )
        XCTAssertEqual(
            SettingsEngine.validateBodyMetric(kind: "bodyWeight", label: nil, value: 0, unit: "kg"),
            .invalidValue("value must be > 0")
        )
        XCTAssertEqual(
            SettingsEngine.validateBodyMetric(kind: "bodyFat", label: nil, value: 101, unit: "pct"),
            .invalidValue("bodyFat must be ≤ 100")
        )
    }

    // MARK: BR-013 — keyed copy wired

    func testEmptyStateCopyCarriesAllNineteenIssue14Keys() {
        let expectedKeys = [
            "home.empty_title", "home.empty_sub", "home.empty_cta", "home.streak_label", "home.startEmpty_cta",
            "activeWorkout.emptyList_line", "activeWorkout.addExercise_cta", "activeWorkout.startEmpty_help",
            "history.empty_title", "history.empty_sub", "history.empty_cta",
            "analytics.empty_title", "analytics.empty_sub", "analytics.empty_cta", "analytics.hint_body",
            "picker.search_empty_title", "picker.search_empty_sub", "picker.createCustom_cta", "picker.browse_hint",
        ]
        XCTAssertEqual(expectedKeys.count, 19)
        for key in expectedKeys {
            let value = SettingsEngine.emptyStateCopy[key]
            XCTAssertNotNil(value, "missing #14 key \(key)")
            XCTAssertFalse(value?.isEmpty ?? true, "empty #14 key \(key)")
        }
        XCTAssertEqual(SettingsEngine.emptyStateCopy["home.empty_title"], "No routines yet")
        XCTAssertEqual(SettingsEngine.emptyStateCopy["analytics.empty_title"], "Nothing to graph yet")
    }

    func testFoundationDbCopyWired() {
        XCTAssertEqual(SettingsEngine.foundationDbCopy.count, 8)
        XCTAssertEqual(SettingsEngine.foundationDbCopy["foundation.db.fatalTitle"], "Storage unavailable")
    }

    // MARK: BR-014 — snapshot defaults

    func testSettingsSnapshotDefaults() {
        let defaults = AppSettingsSnapshot.default
        XCTAssertEqual(defaults.weightUnit, .kg)
        XCTAssertEqual(defaults.defaultRestCompoundSec, 180)
        XCTAssertEqual(defaults.defaultRestIsolationSec, 90)
    }
}
