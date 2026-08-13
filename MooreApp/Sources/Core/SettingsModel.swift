// Ticket #38 — Settings surface app model. Drives the existing MooreSettings
// seams (SC-settings@1.0.0): SettingsEngine (seam-1, pure) + SettingsDAO
// (seam-2, GRDB). No business logic is reimplemented here — this file only
// orchestrates: read → expose, gesture → DAO call → re-read.
//
//   - Units preference (BR-001/INV-ST1): display-only kg/lb. The toggle writes
//     exactly one app_setting row; stored weights stay canonical kg (INV-ST2).
//   - Rest defaults (BR-005): edits SC-rest's two level-4 app_setting keys,
//     upsert-on-change. Resolution stays the rest hierarchy's job — per-set and
//     per-routine overrides still win (SC-rest BR-001 levels 1–3 beat level 4).
//   - Body metrics CRUD (BR-006/BR-007): engine validation gate → DAO writes →
//     date-descending trend list. Rows carry their own unit (INV-ST2); display
//     converts row-unit → active unit at render time (BR-004).
//   - Backup export (§2 micro-machine, BR-008/BR-009): manifest build → full
//     SQLite file copy → share. Tombstones + plannedX ride along verbatim.
//   - Tombstone list/restore (BR-010/INV-ST4): custom exercises only.
//   - Dormant surface (BR-011, INV-ST5): cloud-sync status renders from the
//     engine constant — no handler, no write path. The Hevy-import entry
//     (BR-012) went live in #39: ImportModel (Foundation-only) drives the
//     MooreImport seams behind the SettingsView Data & sync row.
//   - Storage stats: derived from the BR-009 table accounting + file size.
//
// Foundation-only (@Observable, no SwiftUI) so it parses/verifies off-Mac.

import Foundation
import Observation
import GRDB
import MooreSettings

// MARK: - Storage stats (Data & sync render shape)

/// Derived storage accounting for the Data & sync section. Row counts are the
/// BR-009 core-table accounting (the manifest's honest label set — tombstones
/// included); the file size is the on-disk database file itself.
public struct StorageStats: Equatable, Sendable {
    public var fileSizeBytes: Int64
    public var coreRowCount: Int        // sum over the ten core tables, tombstones included
    public var tombstoneCount: Int      // deleted rows kept across the core tables

    public init(fileSizeBytes: Int64, coreRowCount: Int, tombstoneCount: Int) {
        self.fileSizeBytes = fileSizeBytes
        self.coreRowCount = coreRowCount
        self.tombstoneCount = tombstoneCount
    }
}

// MARK: - Body-metric entry draft (BR-006 add-sheet state)

/// The add-entry sheet's working draft. Validation delegates to the pure engine
/// gate (BR-006) — the draft is saveable exactly when the engine returns nil.
public struct BodyMetricEntryDraft: Equatable, Sendable {
    public var kind: String
    public var label: String
    public var valueText: String
    public var unit: String
    public var recordedAt: Date

    /// Entry respect (BR-003): the weight-kind form opens in the active unit.
    public init(weightUnit: WeightUnit, recordedAt: Date = Date()) {
        self.kind = "bodyWeight"
        self.label = ""
        self.valueText = ""
        self.unit = weightUnit.rawValue
        self.recordedAt = recordedAt
    }

    public var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedUnit: String {
        unit.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Locale-tolerant numeric parse ("82.4" or "82,4").
    public var parsedValue: Double? {
        let text = valueText.trimmingCharacters(in: .whitespaces)
        if let direct = Double(text) { return direct }
        return Double(text.replacingOccurrences(of: ",", with: "."))
    }

    /// Kind switch re-seats the unit to the lawful default for the new kind
    /// (§3b unit legality per kind).
    public mutating func setKind(_ newKind: String, weightUnit: WeightUnit) {
        guard newKind != kind else { return }
        kind = newKind
        switch newKind {
        case "bodyWeight": unit = weightUnit.rawValue
        case "bodyFat": unit = "pct"
        default: unit = ""    // measurement: any non-empty unit string as entered
        }
    }

    /// BR-006 gate via the pure engine; nil ⇔ saveable.
    public var validationError: SettingsEngine.BodyMetricValidationError? {
        guard let value = parsedValue else {
            return .invalidValue("value must be a number")
        }
        return SettingsEngine.validateBodyMetric(
            kind: kind,
            label: trimmedLabel.isEmpty ? nil : trimmedLabel,
            value: value,
            unit: trimmedUnit
        )
    }

    public var isValid: Bool { validationError == nil }
}

// MARK: - SettingsModel

@Observable
public final class SettingsModel {

    // MARK: Export micro-machine (SC-settings §2)

    /// §2 states: exportIdle → exportPreparing → exportWriting(manifest) →
    /// exportCompleted(manifest, fileName) | exportFailed(reason) → exportIdle.
    /// The DAO copy is synchronous, so the transitions are fast — the machine
    /// exists for the failure-copy contract (§2: exportFailed surfaces the
    /// foundation.db.* fallback copy), not for async bookkeeping.
    public enum ExportPhase: Equatable, Sendable {
        case idle
        case preparing
        case writing
        case completed
        case failed(String)
    }

    // MARK: Observable state

    /// BR-014 total snapshot: .kg / 180 / 90 until the first change writes a row.
    public private(set) var settings: AppSettingsSnapshot
    /// Trend list (BR-007): live rows, recordedAt DESC — the DAO's order.
    public private(set) var bodyMetrics: [SettingsBodyMetric] = []
    /// BR-010: tombstoned CUSTOM exercises, deletedAt DESC.
    public private(set) var tombstones: [TombstonedExercise] = []
    /// Data & sync storage accounting (derived, never persisted).
    public private(set) var storageStats: StorageStats?
    /// Last write-path error, surfaced inline (copy-driven states, no toasts
    /// except the contract's exportedToast).
    public private(set) var errorMessage: String?

    /// §2 export state.
    public private(set) var exportPhase: ExportPhase = .idle
    public private(set) var exportManifest: SettingsEngine.ExportManifest?
    /// The written `.moore-backup` copy; non-nil while phase == .completed.
    public private(set) var exportFileURL: URL?
    /// Non-nil ⇔ the `settings.dataSync.exportedToast` toast renders.
    public private(set) var exportedToastFileName: String?

    /// Dormant surface (BR-011): rendered constant from the engine. No
    /// handler, no write path (INV-ST5). The Hevy-import entry (BR-012) went
    /// live in #39 — see ImportModel (Foundation-only) + HevyImportFlowView;
    /// the engine's `hevyImportEntry` stub constant is no longer rendered.
    public let cloudSyncStatus = SettingsEngine.cloudSyncStatus

    private let dao: SettingsDAO
    private let iso = ISO8601DateFormatter()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    public init(dao: SettingsDAO) {
        self.dao = dao
        self.settings = (try? dao.fetchSettings()) ?? AppSettingsSnapshot.default
        refreshAll()
    }

    // MARK: Reads (cold-render rule: every list re-reads SQLite)

    public func refreshAll() {
        refreshSettings()
        refreshBodyMetrics()
        refreshTombstones()
        refreshStorageStats()
    }

    public func refreshSettings() {
        do {
            settings = try dao.fetchSettings()
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func refreshBodyMetrics() {
        do {
            bodyMetrics = try dao.listBodyMetrics(kind: nil)
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func refreshTombstones() {
        do {
            tombstones = try dao.listTombstonedCustomExercises()
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Derived from the BR-009 accounting (core ten tables) + the on-disk file
    /// size. Derived, never persisted (SC-foundation INV-5).
    public func refreshStorageStats() {
        do {
            let dumps = try dao.exportSelectDumps()
            let manifest = SettingsEngine.buildExportManifest(tableStats: dumps, exportedAt: "")
            let coreRowCount = manifest.tables.reduce(0) { $0 + $1.rowCount }
            let tombstoneCount = manifest.tables.reduce(0) { $0 + $1.tombstoneCount }
            let attributes = try? FileManager.default.attributesOfItem(atPath: dao.dbQueue.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            storageStats = StorageStats(
                fileSizeBytes: fileSize,
                coreRowCount: coreRowCount,
                tombstoneCount: tombstoneCount
            )
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: Units (BR-001 / INV-ST1)

    /// Display-only toggle: the DAO writes exactly one app_setting row and
    /// nothing else. No stored weight anywhere is rewritten, ever.
    public func setWeightUnit(_ unit: WeightUnit) {
        guard unit != settings.weightUnit else { return }
        do {
            try dao.setWeightUnit(unit, at: now())
            refreshSettings()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: Rest defaults (BR-005)

    /// Edits SC-rest's level-4 keys, upsert-on-change; `nil` = leave unchanged.
    /// The rest hierarchy consumes these rows unchanged — per-set/per-routine
    /// overrides still win (SC-rest BR-001), and resolution clamps there too.
    public func updateRestDefaults(compoundSec: Int? = nil, isolationSec: Int? = nil) {
        guard compoundSec != nil || isolationSec != nil else { return }
        do {
            try dao.updateRestDefaults(compoundSec: compoundSec, isolationSec: isolationSec, at: now())
            refreshSettings()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: Body metrics CRUD (BR-006 / BR-007)

    /// Engine validation gate → DAO insert (rows carry their own unit — INV-ST2)
    /// → re-read in recordedAt-DESC order. Returns success for sheet dismissal.
    @discardableResult
    public func addBodyMetric(_ draft: BodyMetricEntryDraft) -> Bool {
        guard let value = draft.parsedValue else { return false }
        do {
            try dao.addBodyMetric(
                kind: draft.kind,
                label: draft.kind == "measurement" ? draft.trimmedLabel : nil,
                value: value,
                unit: draft.trimmedUnit,
                recordedAt: iso.string(from: draft.recordedAt),
                at: now()
            )
            refreshBodyMetrics()
            refreshStorageStats()
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    /// BR-006 delete = tombstone (SC-foundation BR-003); never a hard delete.
    public func deleteBodyMetric(id: String) {
        do {
            try dao.softDeleteBodyMetric(id: id, at: now())
            refreshBodyMetrics()
            refreshStorageStats()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: Tombstone management (BR-010 / INV-ST4)

    /// Restore clears deletedAt + bumps updatedAt — nothing else changes.
    public func restoreExercise(id: String) {
        do {
            try dao.restoreExercise(id: id, at: now())
            refreshTombstones()
            refreshStorageStats()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: Backup export (§2, BR-008 / BR-009)

    /// exportRequested: idle → preparing (manifest build) → writing (full SQLite
    /// file copy) → completed(manifest, fileName). Any read/write error lands in
    /// failed(reason); the surface maps that onto the foundation.db.* fallback
    /// copy per §2 severity rules.
    public func exportBackup() {
        guard exportPhase != .preparing && exportPhase != .writing else { return }
        exportPhase = .preparing
        exportFileURL = nil
        exportManifest = nil

        let exportedAt = now()
        let manifest: SettingsEngine.ExportManifest
        do {
            manifest = try dao.exportManifest(exportedAt: exportedAt)
        } catch {
            exportPhase = .failed("\(error)")
            return
        }
        exportManifest = manifest
        exportPhase = .writing

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(manifest.fileName)
        do {
            // Never let a stale copy from a prior export shadow the fresh one.
            try? FileManager.default.removeItem(at: destination)
            try dao.exportFullCopy(toPath: destination.path)
        } catch {
            exportPhase = .failed("\(error)")
            return
        }

        exportFileURL = destination
        exportedToastFileName = manifest.fileName     // settings.dataSync.exportedToast {fileName}
        exportPhase = .completed
        refreshStorageStats()
    }

    /// §2 terminal → exportIdle: exportCompleted/exportFailed exit on dismiss.
    public func dismissExportResult() {
        exportPhase = .idle
        exportManifest = nil
        exportFileURL = nil
        exportedToastFileName = nil
    }

    /// Toast auto-dismiss keeps the completed file + ShareLink alive.
    public func clearToast() {
        exportedToastFileName = nil
    }

    // MARK: Display helpers (BR-004 render lens — pure, never writes)

    /// BR-004: weight rows convert row-unit → active unit at 1dp; pct/cm/in pass
    /// through untouched. Mirrors the VerifySettings displayBodyMetricString form.
    public func displayString(for metric: SettingsBodyMetric) -> String {
        let value = SettingsEngine.displayBodyMetric(
            value: metric.value,
            rowUnit: metric.unit,
            target: settings.weightUnit
        )
        let isWeightUnit = metric.unit == "kg" || metric.unit == "lb"
        let unit = isWeightUnit ? settings.weightUnit.rawValue : metric.unit
        return String(format: "%.1f %@", value, unit)
    }

    /// Row/sheet title for a kind: measurement rows lead with their free label.
    public func displayTitle(for metric: SettingsBodyMetric) -> String {
        switch metric.kind {
        case "measurement": return metric.label ?? UICopy.settingsKindMeasurement
        case "bodyFat": return UICopy.settingsKindBodyFat
        default: return UICopy.settingsKindBodyWeight
        }
    }

    /// Timeline-key render: ISO-8601 UTC → "13 Aug 2026"; raw string on parse miss.
    public func displayDate(forISO isoString: String) -> String {
        guard let date = iso.date(from: isoString) else { return isoString }
        return Self.displayDateFormatter.string(from: date)
    }

    /// Human file size for the storage-stats row.
    public static func displayFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Internals

    /// Callers supply `now` to the frozen DAO seams; the app model owns the
    /// wall-clock read (ISO-8601 UTC, same shape the DAOs use internally).
    private func now() -> String {
        iso.string(from: Date())
    }
}
