// Ticket #39 — Hevy CSV import flow app model. Drives the existing MooreImport
// seams (SC-import@1.0.0): HevyCsvParser + HevyImportEngine (seam-1, pure plan
// build, zero DB contact — INV-IM1) and HevyImportDAO (seam-2, ONE-transaction
// apply + PR re-derivation — BR-015/BR-016). No import logic is reimplemented
// here; this file orchestrates the contract's §2 five-state machine:
//
//   idle → parsing → preview → applying → done
//               ↘          ↘          ↘ error
//
//   - parsing:  file read (security-scoped URL from the system picker) + full
//               in-memory plan build (BR-014). Zero DB writes (INV-IM1).
//   - preview:  dry-run counts + quarantine inspection + per-exercise unit
//               overrides. An override edit rebuilds the plan from the same
//               CSV text — the single `plan` property is the ONE object both
//               preview and applying consume (INV-IM5).
//   - applying: one transaction via HevyImportDAO.apply (BR-015). The >50%
//               quarantine abort (BR-012) already fired at plan build, so a
//               started apply is all-or-nothing by construction (INV-IM2).
//   - done:     ImportSummary + PR re-derivation confirmation (BR-016). A
//               re-import of the same file lands as the counted no-op state
//               (BR-013 / INV-IM4) — zero new rows, "already imported".
//   - error:    notHevyExport (BR-002/BR-012/unreadable file) or applyFailed
//               (rolled-back transaction) — nothing persisted.
//
// Target unit is pinned to canonical kg (SC-settings INV-ST2: unit-less weight
// columns are canonical kg; the display-unit toggle never rewrites data —
// BR-001 there). An lb Hevy file under an lb display setting still imports as
// converted kg and renders through the display lens, exactly like native rows.
//
// Foundation-only (@Observable, no SwiftUI) so it parses/verifies off-Mac.

import Foundation
import Observation
import GRDB
import MooreImport

// MARK: - Render-ready plan slice (unit override rows)

/// One exercise the preview offers a unit override for (BR-010/BR-014):
/// distinct over the plan's weight-bearing imported sets — an override only
/// ever touches actualWeight conversion, so duration/reps-only exercises
/// never appear here.
public struct ImportPlanExercise: Identifiable, Equatable, Sendable {
    public let normalizedName: String
    public let displayName: String

    public var id: String { normalizedName }

    public init(normalizedName: String, displayName: String) {
        self.normalizedName = normalizedName
        self.displayName = displayName
    }
}

// MARK: - ImportModel

@Observable
public final class ImportModel {

    /// SC-import §2 state machine. The error state carries the §6 copy kind
    /// plus a technical detail (rendered small, for support).
    public enum Phase: Equatable {
        case idle
        case parsing
        case preview
        case applying
        case done
        case error(ErrorKind, detail: String)
    }

    /// Selects the SC-import §6 error copy (the surface's two-key vocabulary).
    public enum ErrorKind: Equatable {
        /// BR-002 missing headers / BR-012 >50% abort / BR-001 malformed /
        /// unreadable file — nothing parsed into a plan.
        case notHevyExport
        /// BR-015 apply failure — the single transaction rolled back (INV-IM2).
        case applyFailed
    }

    // MARK: Observable state

    public private(set) var phase: Phase = .idle
    /// INV-IM5: the ONE plan both preview and applying consume.
    public private(set) var plan: ImportPlan?
    /// BR-015 result — non-nil only in .done.
    public private(set) var summary: ImportSummary?
    public private(set) var sourceFileName: String?
    /// BR-010 per-exercise overrides: normalized exercise name → declared unit.
    public private(set) var unitOverrides: [String: HevyUnit] = [:]
    /// BR-016 confirmation read: live personal_record rows the apply added.
    public private(set) var prRowsAddedByApply = 0

    private let dao: HevyImportDAO
    private var csvText = ""
    /// The library snapshot the current plan was built against (name lookup
    /// for the override rows; re-probed on every plan build).
    private var librarySnapshot: [LibraryRow] = []
    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public init(dao: HevyImportDAO) {
        self.dao = dao
    }

    // MARK: §2 transitions

    /// file-picked → parsing → preview | error. Reads the picked file and
    /// builds the full dry-run plan in memory (BR-014). Zero DB writes here
    /// (INV-IM1) — the only reads are the BR-013/BR-009 probes below.
    public func loadFile(at url: URL) {
        reset()
        phase = .parsing
        sourceFileName = url.lastPathComponent

        // The document picker hands out security-scoped URLs; access must be
        // started (and stopped) around the read.
        let scoped = url.startAccessingSecurityScopedResource()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            phase = .error(.notHevyExport, detail: "\(error)")
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }

        // BR-001: UTF-8 is the container contract.
        guard let text = String(data: data, encoding: .utf8) else {
            phase = .error(.notHevyExport, detail: "file is not UTF-8 text")
            return
        }
        csvText = text
        rebuildPlan()
    }

    /// The system picker surfaced an unreadable pick (not a user cancel).
    public func filePickFailed(detail: String) {
        reset()
        phase = .error(.notHevyExport, detail: detail)
    }

    /// BR-010 per-exercise override edit (a preview control): record it and
    /// rebuild the plan so preview and applying keep consuming ONE object
    /// (INV-IM5). Pure in-memory rebuild from the same CSV text.
    public func setUnitOverride(normalizedName: String, unit: HevyUnit) {
        guard phase == .preview else { return }
        unitOverrides[normalizedName] = unit
        rebuildPlan()
    }

    /// Override cleared → the file's declared unit governs again (BR-010).
    public func clearUnitOverride(normalizedName: String) {
        guard phase == .preview else { return }
        unitOverrides.removeValue(forKey: normalizedName)
        rebuildPlan()
    }

    /// [Import] → applying → done | error. ONE transaction (BR-015); any
    /// failure rolls back everything (INV-IM2) and lands in .applyFailed.
    public func applyImport() {
        guard phase == .preview, let plan else { return }
        phase = .applying
        let prRowsBefore = livePersonalRecordCount()
        do {
            summary = try dao.apply(plan)
            prRowsAddedByApply = max(0, livePersonalRecordCount() - prRowsBefore)
            phase = .done
        } catch {
            phase = .error(.applyFailed, detail: "\(error)")
        }
    }

    /// Any dismissal/cancel → idle; the plan is discarded wholesale (INV-IM1:
    /// cancel before [Import] never writes). Idempotent.
    public func reset() {
        phase = .idle
        plan = nil
        summary = nil
        sourceFileName = nil
        unitOverrides = [:]
        prRowsAddedByApply = 0
        csvText = ""
        librarySnapshot = []
    }

    // MARK: Derived state (render hooks)

    /// INV-IM4 render: the apply wrote zero new rows ⇔ the file was already
    /// imported — the done screen reads as "already imported", not a failure.
    public var lastImportAddedNothing: Bool {
        guard let summary else { return false }
        return summary.sessionsImported == 0
            && summary.setsImported == 0
            && summary.exercisesCreated == 0
    }

    /// Distinct exercises with ≥1 weight-bearing imported set, first-seen
    /// order — the only rows a unit override can affect (BR-010 converts
    /// actualWeight only).
    public var overridableExercises: [ImportPlanExercise] {
        guard let plan else { return [] }
        var nameById: [String: (normalized: String, display: String)] = [:]
        for row in librarySnapshot {
            nameById[row.id] = (normalized: row.nameNormalized, display: row.name)
        }
        var displayByNewNorm: [String: String] = [:]
        for exercise in plan.newExercises {
            displayByNewNorm[exercise.normalizedName] = exercise.name
        }
        var seen: Set<String> = []
        var ordered: [ImportPlanExercise] = []
        for session in plan.sessions {
            for set in session.sets where set.actualWeight != nil {
                let normalized: String
                let display: String
                switch set.exerciseRef {
                case .existing(let id):
                    guard let row = nameById[id] else { continue }
                    normalized = row.normalized
                    display = row.display
                case .new(let normalizedName):
                    normalized = normalizedName
                    display = displayByNewNorm[normalizedName] ?? normalizedName
                }
                guard !seen.contains(normalized) else { continue }
                seen.insert(normalized)
                ordered.append(ImportPlanExercise(normalizedName: normalized, displayName: display))
            }
        }
        return ordered
    }

    // MARK: Plan build (probes + the pure engine)

    /// Rebuilds `plan` from `csvText` + fresh DB probes + current overrides.
    /// The engine throws notHevyExport on missing headers (BR-002) or the
    /// >50% quarantine abort (BR-012) — both surface as the §6 error copy.
    private func rebuildPlan() {
        do {
            librarySnapshot = try probeLibrary()
            let options = ImportOptions(
                targetUnit: .kg,   // SC-settings INV-ST2: canonical kg storage
                timezoneOffsetMinutes: TimeZone.current.secondsFromGMT() / 60,   // BR-017
                now: iso.string(from: Date()),
                unitOverrides: unitOverrides,
                existingImportKeys: try probeImportKeys()
            )
            plan = try HevyImportEngine.buildPlan(
                csvText: csvText,
                library: librarySnapshot,
                options: options
            )
            phase = .preview
        } catch let error as HevyImportError {
            plan = nil
            switch error {
            case .notHevyExport(let detail), .csvMalformed(let detail):
                phase = .error(.notHevyExport, detail: detail)
            }
        } catch {
            plan = nil
            phase = .error(.notHevyExport, detail: "\(error)")
        }
    }

    /// BR-009 match candidates: live (non-tombstoned) exercise rows — the
    /// seeded built-ins plus existing customs — in the engine's LibraryRow
    /// shape. Tombstones never match (BR-009 filter).
    private func probeLibrary() throws -> [LibraryRow] {
        try dao.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name, name_normalized, equipmentSlug, isCustom
                  FROM exercise
                 WHERE deletedAt IS NULL
                """).map { row in
                let name: String = row["name"]
                let normalized: String? = row["name_normalized"]
                let equipment: String? = row["equipmentSlug"]
                let isCustom: Int = row["isCustom"]
                return LibraryRow(
                    id: row["id"],
                    name: name,
                    nameNormalized: normalized ?? HevyImportEngine.normalize(name),
                    equipmentSlug: equipment,
                    isCustom: isCustom == 1
                )
            }
        }
    }

    /// BR-013 DB probe before plan: live importKeys. The engine marks those
    /// sessions alreadyImported (skipped + counted); the 0003 UNIQUE partial
    /// index + INSERT-OR-IGNORE at apply is the backstop (INV-IM4).
    private func probeImportKeys() throws -> Set<String> {
        try dao.dbQueue.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT importKey
                  FROM workout_session
                 WHERE importKey IS NOT NULL AND deletedAt IS NULL
                """))
        }
    }

    /// BR-016 confirmation read: live personal_record count around the apply.
    /// A failed read counts as 0 — the confirmation is best-effort metadata,
    /// never load-bearing on the apply itself.
    private func livePersonalRecordCount() -> Int {
        let count = try? dao.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personal_record WHERE deletedAt IS NULL")
        }
        return count ?? 0
    }
}
