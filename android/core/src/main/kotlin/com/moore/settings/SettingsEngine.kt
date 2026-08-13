// contractId: SC-settings @1.0.0
// Seam-1 pure engine for the Settings + Data & sync surface (#28).
// Pure JVM — no persistence, no UI, no wall-clock reads (callers supply `now`).
// Mechanical Kotlin port of Sources/MooreSettings/SettingsEngine.swift.
//
// Responsibilities (§5):
//   - Unit conversion helpers (BR-001..BR-004): display-only kg/lb at the
//     frozen 2.20462 ratio; 1dp display, 2dp storage, half-away-from-zero.
//   - Export manifest builder (BR-008/BR-009): .moore-backup naming + the
//     ten-table honest manifest (tombstones + plannedX always included).
//   - Tombstone listing (BR-010): pure filter/sort over exercise rows.
//   - Body-metric validation (BR-006): closed kind vocabulary post-0011.
//   - Keyed copy (BR-013): #14's nineteen empty-state keys + SC-foundation
//     §6's eight fatal-recovery keys + this surface's own keys.
package com.moore.settings

import java.util.Locale
import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.round

// MARK: - Weight unit (§3a)

/// Display unit for weights. Storage stays canonical kg for unit-less weight
/// columns (INV-ST2); toggling this writes one app_setting row, never data.
enum class WeightUnit(val raw: String) {
    KG("kg"), LB("lb");

    companion object {
        fun fromRaw(raw: String?): WeightUnit? = entries.firstOrNull { it.raw == raw }
    }
}

/// Aggregate snapshot the Settings screen binds. Total on a fresh database
/// (BR-014): absent weightUnit row ⇔ kg; rest defaults fall back to
/// SC-rest's seeded values.
data class AppSettingsSnapshot(
    var weightUnit: WeightUnit,
    var defaultRestCompoundSec: Int,
    var defaultRestIsolationSec: Int,
) {
    companion object {
        /// kg / 180 / 90 — the read fallbacks (BR-014, SC-rest INV-S2).
        val DEFAULT = AppSettingsSnapshot(
            weightUnit = WeightUnit.KG,
            defaultRestCompoundSec = 180,
            defaultRestIsolationSec = 90,
        )
    }
}

// MARK: - Engine

object SettingsEngine {

    // MARK: Unit conversion (BR-002 / BR-003 / BR-004)

    /// The one frozen ratio: 1 kg = 2.20462 lb. Spelled, never re-derived.
    const val kgPerLbRatio = 2.20462

    /// Display precision: one decimal place (BR-002).
    const val displayDecimals = 1
    /// Storage/entry-conversion precision: two decimal places (BR-002).
    const val storageDecimals = 2

    fun kgToLb(kg: Double): Double = kg * kgPerLbRatio

    fun lbToKg(lb: Double): Double = lb / kgPerLbRatio

    /// Half-away-from-zero rounding to the given decimal count
    /// (Swift .rounded(.awayFromZero); kotlin.math.round would tie-toward-zero).
    fun round(value: Double, decimals: Int): Double {
        val factor = 10.0.pow(decimals)
        val sign = if (value < 0) -1.0 else 1.0
        return sign * kotlin.math.floor(kotlin.math.abs(value) * factor + 0.5) / factor
    }

    /// 1dp display rounding (BR-002).
    fun roundDisplay(value: Double): Double = round(value, displayDecimals)

    /// 2dp storage rounding (BR-002).
    fun roundStorage(value: Double): Double = round(value, storageDecimals)

    /// Converted display value for a stored canonical-kg weight (BR-001/INV-ST2).
    fun displayValue(rawKg: Double, unit: WeightUnit): Double = when (unit) {
        WeightUnit.KG -> roundDisplay(rawKg)
        WeightUnit.LB -> roundDisplay(kgToLb(rawKg))
    }

    /// "220.5 lb" / "100.0 kg" — the render form of a stored kg weight.
    fun displayString(rawKg: Double, unit: WeightUnit): String =
        String.format(Locale.US, "%.1f %s", displayValue(rawKg, unit), unit.raw)

    /// Entry respect (BR-003): an entered value in the active unit converts to
    /// canonical kg at storage precision before any insert/update.
    fun entryToStorage(entered: Double, unit: WeightUnit): Double = when (unit) {
        WeightUnit.KG -> roundStorage(entered)
        WeightUnit.LB -> roundStorage(lbToKg(entered))
    }

    /// Body-metric display (BR-004): a row carries its own unit; weight units
    /// convert into the active unit at 1dp, pct passes through untouched.
    /// rowUnit outside {kg, lb, pct} passes through as well.
    fun displayBodyMetric(value: Double, rowUnit: String, target: WeightUnit): Double = when (rowUnit) {
        "kg" -> if (target == WeightUnit.KG) roundDisplay(value) else roundDisplay(kgToLb(value))
        "lb" -> if (target == WeightUnit.LB) roundDisplay(value) else roundDisplay(lbToKg(value))
        else -> roundDisplay(value)   // pct / cm / in — no weight dimension
    }

    // MARK: Export manifest (BR-008 / BR-009)

    /// Per-table row accounting for the manifest.
    data class TableStats(
        var table: String,
        var rowCount: Int,          // total rows INCLUDING tombstones
        var tombstoneCount: Int,    // rows with deletedAt NOT NULL (0 if no column)
    )

    /// The honest label on the share sheet (BR-009).
    data class ExportManifest(
        var fileName: String,               // moore-<ts>.moore-backup
        var exportedAt: String,             // ISO-8601 UTC
        var format: String,                 // "sqlite-file-copy"
        var includesTombstones: Boolean,    // always true (INV-ST3)
        var includesPlannedColumns: Boolean, // always true
        var tables: List<TableStats>,       // the ten core tables
    )

    const val backupFileSuffix = ".moore-backup"
    const val exportFormat = "sqlite-file-copy"

    /// The ten core tables of BR-009, in canonical order.
    val coreTableNames: List<String> = listOf(
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
    )

    /// Filename-safe backup name: moore-<exportedAt with ':' → '-'>.moore-backup (BR-008).
    fun backupFileName(exportedAt: String): String =
        "moore-" + exportedAt.replace(":", "-") + backupFileSuffix

    /// Builds the manifest from per-table stats. Stats for tables outside the
    /// ten core names are dropped; missing core tables surface as zero-count
    /// rows so an empty database still manifests all ten (edge case, §7).
    fun buildExportManifest(tableStats: List<TableStats>, exportedAt: String): ExportManifest {
        val byName = tableStats.associateBy { it.table }
        val tables = coreTableNames.map { name ->
            byName[name] ?: TableStats(table = name, rowCount = 0, tombstoneCount = 0)
        }
        return ExportManifest(
            fileName = backupFileName(exportedAt),
            exportedAt = exportedAt,
            format = exportFormat,
            includesTombstones = true,
            includesPlannedColumns = true,
            tables = tables,
        )
    }

    // MARK: Tombstone listing (BR-010)

    /// One exercise row as seen by the tombstone manager.
    data class ExerciseTombstoneRow(
        var id: String,
        var name: String,
        var isCustom: Int,
        var deletedAt: String?,
    )

    /// User-tombstoned CUSTOM exercises only (built-ins are never listed),
    /// ordered deletedAt DESC then name ASC (BR-010).
    fun tombstonedCustomExercises(rows: List<ExerciseTombstoneRow>): List<ExerciseTombstoneRow> {
        return rows
            .filter { it.isCustom == 1 && it.deletedAt != null }
            .sortedWith(compareBy<ExerciseTombstoneRow> { it.deletedAt ?: "" }.reversed()
                .thenBy { it.name })
    }

    // MARK: Dormant surfaces (BR-011 / BR-012)

    /// Cloud sync: permanently greyed at v1 (#4's self-validation gate).
    data class CloudSyncStatus(
        var enabled: Boolean,
        var greyed: Boolean,
        var copyKey: String,
        var infoIssue: String,
    )

    /// Rendered constant — no write path exists behind it (INV-ST5).
    val cloudSyncStatus = CloudSyncStatus(
        enabled = false,
        greyed = true,
        copyKey = "settings.cloudSync.coming",
        infoIssue = "#4",
    )

    /// Hevy import: the entry point lands here, the implementation in #30.
    data class HevyImportEntry(
        var enabled: Boolean,
        var blockedByTicket: String,
        var copyKey: String,
    )

    /// Stub (BR-012): invoking it writes nothing (INV-ST5).
    val hevyImportEntry = HevyImportEntry(
        enabled = false,
        blockedByTicket = "#30",
        copyKey = "settings.dataSync.importHevy",
    )

    // MARK: Body-metric validation (BR-006, INV-ST6)

    sealed class BodyMetricValidationError(val code: String) {
        class InvalidKind(val kind: String) : BodyMetricValidationError("invalidKind")
        object MeasurementRequiresLabel : BodyMetricValidationError("measurementRequiresLabel")
        class InvalidUnit(val kind: String, val unit: String) : BodyMetricValidationError("invalidUnit")
        class InvalidValue(val message: String) : BodyMetricValidationError("invalidValue")
    }

    /// Closed kind vocabulary post-0011.
    val bodyMetricKinds: List<String> = listOf("bodyWeight", "bodyFat", "measurement")

    /// Pure validation gate for body-metric create/update (BR-006). Returns null
    /// when the entry is lawful; the DAO rejects with the returned error and
    /// writes nothing.
    fun validateBodyMetric(
        kind: String,
        label: String?,
        value: Double,
        unit: String,
    ): BodyMetricValidationError? {
        if (kind !in bodyMetricKinds) return BodyMetricValidationError.InvalidKind(kind)
        if (kind == "measurement" && (label ?: "").trim().isEmpty()) {
            return BodyMetricValidationError.MeasurementRequiresLabel
        }
        when (kind) {
            "bodyWeight" -> if (unit != "kg" && unit != "lb") return BodyMetricValidationError.InvalidUnit(kind, unit)
            "bodyFat" -> if (unit != "pct") return BodyMetricValidationError.InvalidUnit(kind, unit)
            else -> if (unit.trim().isEmpty()) return BodyMetricValidationError.InvalidUnit(kind, unit) // measurement: any non-empty unit
        }
        if (!value.isFinite() || value <= 0) return BodyMetricValidationError.InvalidValue("value must be > 0")
        if (kind == "bodyFat" && value > 100) return BodyMetricValidationError.InvalidValue("bodyFat must be ≤ 100")
        return null
    }

    // MARK: Keyed copy (§6, BR-013)

    /// #14's empty-state keys, wired verbatim from #14's resolution comment.
    val emptyStateCopy: Map<String, String> = mapOf(
        "home.empty_title" to "No routines yet",
        "home.empty_sub" to "Routines are your gym days. Create one and your next workout is one tap to start.",
        "home.empty_cta" to "Create your first routine",
        "home.streak_label" to "{n}-day streak",
        "home.startEmpty_cta" to "Start empty",
        "activeWorkout.emptyList_line" to "No sets yet",
        "activeWorkout.addExercise_cta" to "+ Add exercise",
        "activeWorkout.startEmpty_help" to "Add an exercise to start logging",
        "history.empty_title" to "No sessions yet",
        "history.empty_sub" to "Your gym visits will live here.",
        "history.empty_cta" to "Start a workout",
        "analytics.empty_title" to "Nothing to graph yet",
        "analytics.empty_sub" to "Log 3 sessions to start seeing trends.",
        "analytics.empty_cta" to "Log your first session",
        "analytics.hint_body" to "Every workout builds your stats.",
        "picker.search_empty_title" to "No matches",
        "picker.search_empty_sub" to "Check spelling or create it custom.",
        "picker.createCustom_cta" to "Create custom exercise",
        "picker.browse_hint" to "Or scroll to browse",
    )

    /// SC-foundation §6 fatal-recovery keys — that contract names SC-settings
    /// as the wiring owner. Verbatim.
    val foundationDbCopy: Map<String, String> = mapOf(
        "foundation.db.fatalTitle" to "Storage unavailable",
        "foundation.db.fatalBody" to "Moore's local database can't be opened. Your training data may be at risk. Export a backup from Settings if you can, then reinstall the app.",
        "foundation.db.fatalAction" to "Export backup",
        "foundation.db.migrationFailedTitle" to "Update failed",
        "foundation.db.migrationFailedBody" to "This update requires a database change that didn't complete. Don't delete the app — export your data and contact support.",
        "foundation.db.migrationFailedAction" to "Contact support",
        "foundation.db.corrupted" to "The database file is damaged. Restore from your last backup.",
        "foundation.db.unknownError" to "Something went wrong with local storage. Try again.",
    )

    /// This surface's own keys (§6).
    val settingsCopy: Map<String, String> = mapOf(
        "settings.title" to "Settings",
        "settings.units.title" to "Units",
        "settings.units.weight" to "Weight unit",
        "settings.restDefaults.title" to "Rest defaults",
        "settings.restDefaults.compound" to "Compound lifts",
        "settings.restDefaults.isolation" to "Isolation",
        "settings.restDefaults.value" to "{n}s",
        "settings.bodyMetrics.title" to "Body metrics",
        "settings.bodyMetrics.addCta" to "Add entry",
        "settings.bodyMetrics.empty" to "No entries yet",
        "settings.bodyMetrics.trendTitle" to "Trend",
        "settings.dataSync.title" to "Data & sync",
        "settings.dataSync.exportCta" to "Export backup",
        "settings.dataSync.exportedToast" to "Backup saved: {fileName}",
        "settings.dataSync.importHevy" to "Import from Hevy",
        "settings.dataSync.importHevyBlocked" to "Available after import ships",
        "settings.cloudSync.title" to "Cloud sync",
        "settings.cloudSync.coming" to "Coming after self-validation gate",
        "settings.tombstones.title" to "Deleted custom exercises",
        "settings.tombstones.restoreCta" to "Restore",
        "settings.tombstones.empty" to "Nothing deleted",
    )
}
