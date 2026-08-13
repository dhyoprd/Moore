// contractId: SC-settings @1.0.0
// Seam-1 pure engine for the Settings + Data & sync surface (#28).
// Foundation only — no GRDB, no SwiftUI, no wall-clock reads (callers supply
// `now`). The JS mirror in Tests/MooreSettingsTests/VerifySettings.mjs is the
// platform-free check on this logic; if the two drift, SettingsEngineTests on
// an iOS host catches it.
//
// Responsibilities (§5):
//   - Unit conversion helpers (BR-001..BR-004): display-only kg/lb at the
//     frozen 2.20462 ratio; 1dp display, 2dp storage, half-away-from-zero.
//   - Export manifest builder (BR-008/BR-009): `.moore-backup` naming + the
//     ten-table honest manifest (tombstones + plannedX always included).
//   - Tombstone listing (BR-010): pure filter/sort over exercise rows.
//   - Body-metric validation (BR-006): closed kind vocabulary post-0011.
//   - Keyed copy (BR-013): #14's nineteen empty-state keys + SC-foundation
//     §6's eight fatal-recovery keys + this surface's own keys.

import Foundation

// MARK: - Weight unit (§3a)

/// Display unit for weights. Storage stays canonical kg for unit-less weight
/// columns (INV-ST2); toggling this writes one `app_setting` row, never data
/// (BR-001 / INV-ST1).
public enum WeightUnit: String, Codable, CaseIterable, Sendable {
    case kg
    case lb
}

/// Aggregate snapshot the Settings screen binds. Total on a fresh database
/// (BR-014): absent `weightUnit` row ⇔ `.kg`; rest defaults fall back to
/// SC-rest's seeded values.
public struct AppSettingsSnapshot: Equatable, Sendable {
    public var weightUnit: WeightUnit
    public var defaultRestCompoundSec: Int
    public var defaultRestIsolationSec: Int

    public init(weightUnit: WeightUnit, defaultRestCompoundSec: Int, defaultRestIsolationSec: Int) {
        self.weightUnit = weightUnit
        self.defaultRestCompoundSec = defaultRestCompoundSec
        self.defaultRestIsolationSec = defaultRestIsolationSec
    }

    /// .kg / 180 / 90 — the read fallbacks (BR-014, SC-rest INV-S2).
    public static let `default` = AppSettingsSnapshot(
        weightUnit: .kg,
        defaultRestCompoundSec: 180,
        defaultRestIsolationSec: 90
    )
}

// MARK: - Engine

public enum SettingsEngine {

    // MARK: Unit conversion (BR-002 / BR-003 / BR-004)

    /// The one frozen ratio: 1 kg = 2.20462 lb. Spelled, never re-derived.
    public static let kgPerLbRatio: Double = 2.20462

    /// Display precision: one decimal place (BR-002).
    public static let displayDecimals = 1
    /// Storage/entry-conversion precision: two decimal places (BR-002).
    public static let storageDecimals = 2

    public static func kgToLb(_ kg: Double) -> Double {
        kg * kgPerLbRatio
    }

    public static func lbToKg(_ lb: Double) -> Double {
        lb / kgPerLbRatio
    }

    /// Half-away-from-zero rounding to the given decimal count.
    public static func round(_ value: Double, decimals: Int) -> Double {
        let factor = pow(10.0, Double(decimals))
        return (value * factor).rounded(.awayFromZero) / factor
    }

    /// 1dp display rounding (BR-002).
    public static func roundDisplay(_ value: Double) -> Double {
        round(value, decimals: displayDecimals)
    }

    /// 2dp storage rounding (BR-002).
    public static func roundStorage(_ value: Double) -> Double {
        round(value, decimals: storageDecimals)
    }

    /// Converted display value for a stored canonical-kg weight (BR-001/INV-ST2).
    public static func displayValue(rawKg: Double, unit: WeightUnit) -> Double {
        switch unit {
        case .kg: return roundDisplay(rawKg)
        case .lb: return roundDisplay(kgToLb(rawKg))
        }
    }

    /// "220.5 lb" / "100.0 kg" — the render form of a stored kg weight.
    public static func displayString(rawKg: Double, unit: WeightUnit) -> String {
        String(format: "%.1f %@", displayValue(rawKg: rawKg, unit: unit), unit.rawValue)
    }

    /// Entry respect (BR-003): an entered value in the active unit converts to
    /// canonical kg at storage precision before any insert/update.
    public static func entryToStorage(_ entered: Double, unit: WeightUnit) -> Double {
        switch unit {
        case .kg: return roundStorage(entered)
        case .lb: return roundStorage(lbToKg(entered))
        }
    }

    /// Body-metric display (BR-004): a row carries its own unit; weight units
    /// convert into the active unit at 1dp, `pct` passes through untouched.
    /// `rowUnit` outside {kg, lb, pct} passes through as well (measurement rows
    /// render their stored value + unit verbatim at 1dp).
    public static func displayBodyMetric(value: Double, rowUnit: String, target: WeightUnit) -> Double {
        switch rowUnit {
        case "kg":
            return target == .kg ? roundDisplay(value) : roundDisplay(kgToLb(value))
        case "lb":
            return target == .lb ? roundDisplay(value) : roundDisplay(lbToKg(value))
        default:
            return roundDisplay(value)   // pct / cm / in — no weight dimension
        }
    }

    // MARK: Export manifest (BR-008 / BR-009)

    /// Per-table row accounting for the manifest.
    public struct TableStats: Equatable, Sendable {
        public var table: String
        public var rowCount: Int          // total rows INCLUDING tombstones
        public var tombstoneCount: Int    // rows with deletedAt NOT NULL (0 if no column)

        public init(table: String, rowCount: Int, tombstoneCount: Int) {
            self.table = table
            self.rowCount = rowCount
            self.tombstoneCount = tombstoneCount
        }
    }

    /// The honest label on the share sheet (BR-009).
    public struct ExportManifest: Equatable, Sendable {
        public var fileName: String               // moore-<ts>.moore-backup
        public var exportedAt: String             // ISO-8601 UTC
        public var format: String                 // "sqlite-file-copy"
        public var includesTombstones: Bool       // always true (INV-ST3)
        public var includesPlannedColumns: Bool   // always true
        public var tables: [TableStats]           // the ten core tables

        public init(
            fileName: String,
            exportedAt: String,
            format: String,
            includesTombstones: Bool,
            includesPlannedColumns: Bool,
            tables: [TableStats]
        ) {
            self.fileName = fileName
            self.exportedAt = exportedAt
            self.format = format
            self.includesTombstones = includesTombstones
            self.includesPlannedColumns = includesPlannedColumns
            self.tables = tables
        }
    }

    public static let backupFileSuffix = ".moore-backup"
    public static let exportFormat = "sqlite-file-copy"

    /// The ten core tables of BR-009, in canonical order.
    public static let coreTableNames: [String] = [
        "folder",
        "exercise",
        "routine",
        "planned_set",
        "workout_session",
        "completed_set",
        "personal_record",
        "body_metric",
        "progression_scheme",
        "app_setting",
    ]

    /// Filename-safe backup name: `moore-<exportedAt with ':' → '-'>.moore-backup`,
    /// e.g. `moore-2026-08-13T09-30-00Z.moore-backup` (BR-008).
    public static func backupFileName(exportedAt: String) -> String {
        "moore-" + exportedAt.replacingOccurrences(of: ":", with: "-") + backupFileSuffix
    }

    /// Builds the manifest from per-table stats. Stats for tables outside the
    /// ten core names are dropped (legacy `__legacy_*` tables ride along in the
    /// file copy itself — INV-ST3 — but the manifest labels the core ten).
    /// Missing core tables surface as zero-count rows so an empty database
    /// still manifests all ten (edge case, §7).
    public static func buildExportManifest(tableStats: [TableStats], exportedAt: String) -> ExportManifest {
        var byName: [String: TableStats] = [:]
        for stats in tableStats {
            byName[stats.table] = stats
        }
        let tables = coreTableNames.map { name in
            byName[name] ?? TableStats(table: name, rowCount: 0, tombstoneCount: 0)
        }
        return ExportManifest(
            fileName: backupFileName(exportedAt: exportedAt),
            exportedAt: exportedAt,
            format: exportFormat,
            includesTombstones: true,
            includesPlannedColumns: true,
            tables: tables
        )
    }

    // MARK: Tombstone listing (BR-010)

    /// One exercise row as seen by the tombstone manager.
    public struct ExerciseTombstoneRow: Equatable, Sendable {
        public var id: String
        public var name: String
        public var isCustom: Int
        public var deletedAt: String?

        public init(id: String, name: String, isCustom: Int, deletedAt: String?) {
            self.id = id
            self.name = name
            self.isCustom = isCustom
            self.deletedAt = deletedAt
        }
    }

    /// User-tombstoned CUSTOM exercises only (built-ins are never listed),
    /// ordered deletedAt DESC then name ASC. Pure filter/sort — the DAO supplies
    /// rows, this decides which ones the surface shows (BR-010).
    public static func tombstonedCustomExercises(from rows: [ExerciseTombstoneRow]) -> [ExerciseTombstoneRow] {
        rows
            .filter { $0.isCustom == 1 && $0.deletedAt != nil }
            .sorted { lhs, rhs in
                let l = lhs.deletedAt ?? ""
                let r = rhs.deletedAt ?? ""
                if l != r { return l > r }          // deletedAt DESC
                return lhs.name < rhs.name          // name ASC tiebreak
            }
    }

    // MARK: Dormant surfaces (BR-011 / BR-012)

    /// Cloud sync: permanently greyed at v1 (#4's self-validation gate).
    public struct CloudSyncStatus: Equatable, Sendable {
        public var enabled: Bool
        public var greyed: Bool
        public var copyKey: String
        public var infoIssue: String

        public init(enabled: Bool, greyed: Bool, copyKey: String, infoIssue: String) {
            self.enabled = enabled
            self.greyed = greyed
            self.copyKey = copyKey
            self.infoIssue = infoIssue
        }
    }

    /// Rendered constant — no write path exists behind it (INV-ST5).
    public static let cloudSyncStatus = CloudSyncStatus(
        enabled: false,
        greyed: true,
        copyKey: "settings.cloudSync.coming",
        infoIssue: "#4"
    )

    /// Hevy import: the entry point lands here, the implementation in #30.
    public struct HevyImportEntry: Equatable, Sendable {
        public var enabled: Bool
        public var blockedByTicket: String
        public var copyKey: String

        public init(enabled: Bool, blockedByTicket: String, copyKey: String) {
            self.enabled = enabled
            self.blockedByTicket = blockedByTicket
            self.copyKey = copyKey
        }
    }

    /// Stub (BR-012): invoking it writes nothing (INV-ST5).
    public static let hevyImportEntry = HevyImportEntry(
        enabled: false,
        blockedByTicket: "#30",
        copyKey: "settings.dataSync.importHevy"
    )

    // MARK: Body-metric validation (BR-006, INV-ST6)

    public enum BodyMetricValidationError: Error, Equatable, Sendable {
        case invalidKind(String)
        case measurementRequiresLabel
        case invalidUnit(kind: String, unit: String)
        case invalidValue(String)
    }

    /// Closed kind vocabulary post-0011.
    public static let bodyMetricKinds: [String] = ["bodyWeight", "bodyFat", "measurement"]

    /// Pure validation gate for body-metric create/update (BR-006). Returns nil
    /// when the entry is lawful; the DAO rejects with the returned error and
    /// writes nothing.
    public static func validateBodyMetric(
        kind: String,
        label: String?,
        value: Double,
        unit: String
    ) -> BodyMetricValidationError? {
        guard bodyMetricKinds.contains(kind) else {
            return .invalidKind(kind)
        }
        if kind == "measurement" && (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .measurementRequiresLabel
        }
        switch kind {
        case "bodyWeight":
            if unit != "kg" && unit != "lb" { return .invalidUnit(kind: kind, unit: unit) }
        case "bodyFat":
            if unit != "pct" { return .invalidUnit(kind: kind, unit: unit) }
        default: // measurement: any non-empty unit string as entered
            if unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .invalidUnit(kind: kind, unit: unit)
            }
        }
        guard value.isFinite, value > 0 else {
            return .invalidValue("value must be > 0")
        }
        if kind == "bodyFat" && value > 100 {
            return .invalidValue("bodyFat must be ≤ 100")
        }
        return nil
    }

    // MARK: Keyed copy (§6, BR-013)

    /// #14's empty-state keys, wired verbatim from #14's resolution comment.
    public static let emptyStateCopy: [String: String] = [
        "home.empty_title": "No routines yet",
        "home.empty_sub": "Routines are your gym days. Create one and your next workout is one tap to start.",
        "home.empty_cta": "Create your first routine",
        "home.streak_label": "{n}-day streak",
        "home.startEmpty_cta": "Start empty",
        "activeWorkout.emptyList_line": "No sets yet",
        "activeWorkout.addExercise_cta": "+ Add exercise",
        "activeWorkout.startEmpty_help": "Add an exercise to start logging",
        "history.empty_title": "No sessions yet",
        "history.empty_sub": "Your gym visits will live here.",
        "history.empty_cta": "Start a workout",
        "analytics.empty_title": "Nothing to graph yet",
        "analytics.empty_sub": "Log 3 sessions to start seeing trends.",
        "analytics.empty_cta": "Log your first session",
        "analytics.hint_body": "Every workout builds your stats.",
        "picker.search_empty_title": "No matches",
        "picker.search_empty_sub": "Check spelling or create it custom.",
        "picker.createCustom_cta": "Create custom exercise",
        "picker.browse_hint": "Or scroll to browse",
    ]

    /// SC-foundation §6 fatal-recovery keys — that contract names SC-settings
    /// as the wiring owner. Verbatim.
    public static let foundationDbCopy: [String: String] = [
        "foundation.db.fatalTitle": "Storage unavailable",
        "foundation.db.fatalBody": "Moore's local database can't be opened. Your training data may be at risk. Export a backup from Settings if you can, then reinstall the app.",
        "foundation.db.fatalAction": "Export backup",
        "foundation.db.migrationFailedTitle": "Update failed",
        "foundation.db.migrationFailedBody": "This update requires a database change that didn't complete. Don't delete the app — export your data and contact support.",
        "foundation.db.migrationFailedAction": "Contact support",
        "foundation.db.corrupted": "The database file is damaged. Restore from your last backup.",
        "foundation.db.unknownError": "Something went wrong with local storage. Try again.",
    ]

    /// This surface's own keys (§6).
    public static let settingsCopy: [String: String] = [
        "settings.title": "Settings",
        "settings.units.title": "Units",
        "settings.units.weight": "Weight unit",
        "settings.restDefaults.title": "Rest defaults",
        "settings.restDefaults.compound": "Compound lifts",
        "settings.restDefaults.isolation": "Isolation",
        "settings.restDefaults.value": "{n}s",
        "settings.bodyMetrics.title": "Body metrics",
        "settings.bodyMetrics.addCta": "Add entry",
        "settings.bodyMetrics.empty": "No entries yet",
        "settings.bodyMetrics.trendTitle": "Trend",
        "settings.dataSync.title": "Data & sync",
        "settings.dataSync.exportCta": "Export backup",
        "settings.dataSync.exportedToast": "Backup saved: {fileName}",
        "settings.dataSync.importHevy": "Import from Hevy",
        "settings.dataSync.importHevyBlocked": "Available after import ships",
        "settings.cloudSync.title": "Cloud sync",
        "settings.cloudSync.coming": "Coming after self-validation gate",
        "settings.tombstones.title": "Deleted custom exercises",
        "settings.tombstones.restoreCta": "Restore",
        "settings.tombstones.empty": "Nothing deleted",
    ]
}
