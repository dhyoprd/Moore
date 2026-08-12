// contractId: SC-import @1.0.0
// §4 BR-002…BR-014 — the pure mapping layer. CSV text + library rows + options in,
// ImportPlan out. Seam-1: Foundation only, no GRDB, no UI, zero DB contact
// (INV-IM1). Byte-identical semantics across platforms per §9; the JS verifier
// (Tests/MooreImportTests/VerifyImport.mjs) mirrors this file function-for-function.
//
// Pipeline: parse records → normalize headers → per-row validation (quarantine)
// → group by (startedAt, lower(trim(title))) → map rows to CompletedSets
// (status=completed, plannedX NULL) → resolve exercises (match vs custom)
// → unit conversion → importKey + already-imported skip → PreviewCounts.

import Foundation

// MARK: - Value types (§3b)

public enum HevyUnit: String, Codable, Sendable { case kg, lb }

public struct ImportOptions: Equatable, Sendable {
    public var targetUnit: HevyUnit                 // BR-010; default kg
    public var timezoneOffsetMinutes: Int           // BR-004/BR-017 device-local at import
    public var now: String                          // ISO-8601 UTC write stamp
    public var unitOverrides: [String: HevyUnit]    // BR-010 normalized exercise name → unit
    public var existingImportKeys: Set<String>      // BR-013 DB probe

    public init(
        targetUnit: HevyUnit = .kg,
        timezoneOffsetMinutes: Int = 0,
        now: String,
        unitOverrides: [String: HevyUnit] = [:],
        existingImportKeys: Set<String> = []
    ) {
        self.targetUnit = targetUnit
        self.timezoneOffsetMinutes = timezoneOffsetMinutes
        self.now = now
        self.unitOverrides = unitOverrides
        self.existingImportKeys = existingImportKeys
    }
}

public struct LibraryRow: Equatable, Sendable {
    public var id: String
    public var name: String
    public var nameNormalized: String
    public var equipmentSlug: String?
    public var isCustom: Bool

    public init(id: String, name: String, nameNormalized: String, equipmentSlug: String?, isCustom: Bool) {
        self.id = id
        self.name = name
        self.nameNormalized = nameNormalized
        self.equipmentSlug = equipmentSlug
        self.isCustom = isCustom
    }
}

public struct QuarantinedRow: Equatable, Sendable {
    public var rowNumber: Int        // 1-based data-record index after the header record
    public var column: String
    public var value: String
    public var message: String

    public init(rowNumber: Int, column: String, value: String, message: String) {
        self.rowNumber = rowNumber
        self.column = column
        self.value = value
        self.message = message
    }
}

/// Set → exercise linkage: an existing row id, or a pending custom keyed by
/// normalized name (the DAO mints UUIDs at apply time, INV-IM8).
public enum ExerciseRef: Equatable, Sendable {
    case existing(String)
    case new(normalizedName: String)
}

public struct ImportSetPlan: Equatable, Sendable {
    public var exerciseRef: ExerciseRef
    public var sortOrder: Int
    public var actualWeight: Double?
    public var actualReps: Int?
    public var actualDuration: Int?
    public var completedAt: String   // BR-006: session endedAt ?? startedAt

    public init(exerciseRef: ExerciseRef, sortOrder: Int, actualWeight: Double?, actualReps: Int?, actualDuration: Int?, completedAt: String) {
        self.exerciseRef = exerciseRef
        self.sortOrder = sortOrder
        self.actualWeight = actualWeight
        self.actualReps = actualReps
        self.actualDuration = actualDuration
        self.completedAt = completedAt
    }
}

public struct ImportSessionPlan: Equatable, Sendable {
    public var importKey: String
    public var name: String
    public var notes: String?
    public var startedAt: String     // ISO-8601 UTC, second precision
    public var endedAt: String?
    public var sets: [ImportSetPlan]
    public var alreadyImported: Bool // BR-013: excluded from apply, counted

    public init(importKey: String, name: String, notes: String?, startedAt: String, endedAt: String?, sets: [ImportSetPlan], alreadyImported: Bool) {
        self.importKey = importKey
        self.name = name
        self.notes = notes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sets = sets
        self.alreadyImported = alreadyImported
    }
}

public struct NewExercisePlan: Equatable, Sendable {
    public var name: String            // displayForm, case preserved (BR-009)
    public var normalizedName: String
    public var metric: String          // "reps" | "duration" (BR-009/INV-IM8)

    public init(name: String, normalizedName: String, metric: String) {
        self.name = name
        self.normalizedName = normalizedName
        self.metric = metric
    }
}

public struct MetadataDroppedCounts: Equatable, Sendable {
    public var rpe = 0
    public var exerciseNotes = 0
    public var supersetId = 0
    public init() {}
}

public struct PreviewCounts: Equatable, Sendable {
    public var dataRows = 0
    public var emptyRowsSkipped = 0
    public var duplicatesCollapsed = 0
    public var sessionsFound = 0
    public var setsImported = 0
    public var exercisesMatched = 0
    public var sessionsAlreadyImported = 0
    public var cardioRowsSkipped = 0
    public var foldedSetTypes = 0
    public var quarantinedCount = 0
    public var metadataDropped = MetadataDroppedCounts()
    public init() {}
}

public struct ImportPlan: Equatable, Sendable {
    public var unit: HevyUnit?
    public var now: String                 // write-metadata stamp from ImportOptions
    public var sessions: [ImportSessionPlan]
    public var newExercises: [NewExercisePlan]
    public var quarantined: [QuarantinedRow]
    public var counts: PreviewCounts
    public var warnings: [String]

    public init(unit: HevyUnit?, now: String, sessions: [ImportSessionPlan], newExercises: [NewExercisePlan], quarantined: [QuarantinedRow], counts: PreviewCounts, warnings: [String]) {
        self.unit = unit
        self.now = now
        self.sessions = sessions
        self.newExercises = newExercises
        self.quarantined = quarantined
        self.counts = counts
        self.warnings = warnings
    }
}

public enum HevyImportError: Error, Equatable, CustomStringConvertible {
    case notHevyExport(String)       // BR-002 missing headers / BR-012 >50% abort
    case csvMalformed(String)        // BR-001 parse failure

    public var description: String {
        switch self {
        case .notHevyExport(let msg): return "notHevyExport: \(msg)"
        case .csvMalformed(let msg):  return "csvMalformed: \(msg)"
        }
    }
}

// MARK: - Engine

public enum HevyImportEngine {

    /// Untitled-session name fallback (BR-005; §6 `hevyImport.untitledSession`).
    public static let untitledSessionName = "Imported workout"

    /// BR-010 conversion constants (SC-plate-calculator BR-005 parity).
    public static let kgPerLb = 1.0 / 2.20462
    public static let lbPerKg = 2.20462

    /// Recognized columns (BR-002). Anything else is ignored (forward-compat).
    public static let recognizedColumns: Set<String> = [
        "title", "start_time", "end_time", "description", "exercise_title",
        "superset_id", "exercise_notes", "set_index", "set_type",
        "weight_kg", "weight_lbs", "reps", "distance_km", "distance_miles",
        "duration_seconds", "rpe",
    ]

    /// Full-file pure plan build. Throws `HevyImportError.notHevyExport` on
    /// missing required headers (BR-002) or the >50% quarantine abort (BR-012).
    public static func buildPlan(
        csvText: String,
        library: [LibraryRow],
        options: ImportOptions
    ) throws -> ImportPlan {
        let records: [[String]]
        do {
            records = try HevyCsvParser.parseRecords(csvText)
        } catch {
            throw HevyImportError.csvMalformed("\(error)")
        }
        guard let headerRecord = records.first else {
            throw HevyImportError.notHevyExport("empty file — no header record")
        }

        // ---- Header map (BR-002): first occurrence wins, duplicates warn.
        var columnIndex: [String: Int] = [:]
        var warnings: [String] = []
        for (idx, raw) in headerRecord.enumerated() {
            let norm = HevyCsvParser.normalizeHeader(raw)
            guard recognizedColumns.contains(norm) else { continue }
            if columnIndex[norm] != nil {
                warnings.append("duplicate header '\(norm)' — first occurrence wins")
            } else {
                columnIndex[norm] = idx
            }
        }
        guard columnIndex["start_time"] != nil, columnIndex["exercise_title"] != nil else {
            throw HevyImportError.notHevyExport("missing required header(s): start_time / exercise_title")
        }

        // ---- Declared unit (BR-010): presence of the weight column decides.
        let hasKg = columnIndex["weight_kg"] != nil
        let hasLb = columnIndex["weight_lbs"] != nil
        let declaredUnit: HevyUnit?
        if hasKg && hasLb {
            declaredUnit = .kg
            warnings.append("both weight_kg and weight_lbs present — kg wins")
        } else if hasKg {
            declaredUnit = .kg
        } else if hasLb {
            declaredUnit = .lb
        } else {
            declaredUnit = nil
        }

        func cell(_ record: [String], _ column: String) -> String {
            guard let idx = columnIndex[column], idx < record.count else { return "" }
            return record[idx]
        }

        // ---- Row pass: validation, quarantine, metadata counts.
        var counts = PreviewCounts()
        var quarantined: [QuarantinedRow] = []
        counts.dataRows = records.count - 1

        struct ValidatedRow {
            let rowNumber: Int
            let title: String              // trimmed raw (key uses lower(trim))
            let description: String        // trimmed raw
            let startTime: Date
            let startTimeISO: String
            let endTimeRaw: String
            let exerciseTitle: String      // trimmed raw
            let setIndexRaw: String        // trimmed raw
            let setType: String            // lowercased-trimmed
            let weightRaw: String          // from the governing column
            let repsRaw: String
            let distanceKmRaw: String
            let distanceMilesRaw: String
            let durationRaw: String
        }
        var validRows: [ValidatedRow] = []

        let dataRecords = records.dropFirst()
        for (index, record) in dataRecords.enumerated() {
            let rowNumber = index + 1
            // BR-003: every cell blank-after-trim → skipped silently.
            if record.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                counts.emptyRowsSkipped += 1
                continue
            }
            let title = cell(record, "title").trimmingCharacters(in: .whitespacesAndNewlines)
            let startRaw = cell(record, "start_time").trimmingCharacters(in: .whitespacesAndNewlines)
            let exerciseTitle = cell(record, "exercise_title").trimmingCharacters(in: .whitespacesAndNewlines)
            let setIndexRaw = cell(record, "set_index").trimmingCharacters(in: .whitespacesAndNewlines)
            let setTypeRaw = cell(record, "set_type").trimmingCharacters(in: .whitespacesAndNewlines)
            let weightKgRaw = cell(record, "weight_kg").trimmingCharacters(in: .whitespacesAndNewlines)
            let weightLbsRaw = cell(record, "weight_lbs").trimmingCharacters(in: .whitespacesAndNewlines)
            let repsRaw = cell(record, "reps").trimmingCharacters(in: .whitespacesAndNewlines)
            let distanceKmRaw = cell(record, "distance_km").trimmingCharacters(in: .whitespacesAndNewlines)
            let distanceMilesRaw = cell(record, "distance_miles").trimmingCharacters(in: .whitespacesAndNewlines)
            let durationRaw = cell(record, "duration_seconds").trimmingCharacters(in: .whitespacesAndNewlines)
            let rpeRaw = cell(record, "rpe").trimmingCharacters(in: .whitespacesAndNewlines)
            let exerciseNotesRaw = cell(record, "exercise_notes").trimmingCharacters(in: .whitespacesAndNewlines)
            let supersetRaw = cell(record, "superset_id").trimmingCharacters(in: .whitespacesAndNewlines)
            let description = cell(record, "description").trimmingCharacters(in: .whitespacesAndNewlines)

            // BR-004: start_time is the identity carrier; failure quarantines.
            guard let startDate = parseHevyDateTime(startRaw, offsetMinutes: options.timezoneOffsetMinutes) else {
                quarantined.append(QuarantinedRow(rowNumber: rowNumber, column: "start_time", value: startRaw, message: "unparseable start_time"))
                continue
            }
            // BR-012(b): blank exercise_title.
            if exerciseTitle.isEmpty {
                quarantined.append(QuarantinedRow(rowNumber: rowNumber, column: "exercise_title", value: "", message: "blank exercise_title"))
                continue
            }
            // BR-012(c): malformed numerics.
            if !setIndexRaw.isEmpty && Int(setIndexRaw) == nil {
                quarantined.append(QuarantinedRow(rowNumber: rowNumber, column: "set_index", value: setIndexRaw, message: "malformed set_index"))
                continue
            }
            if !weightKgRaw.isEmpty && Double(weightKgRaw) == nil {
                quarantined.append(QuarantinedRow(rowNumber: rowNumber, column: "weight_kg", value: weightKgRaw, message: "malformed weight_kg"))
                continue
            }
            if !weightLbsRaw.isEmpty && Double(weightLbsRaw) == nil {
                quarantined.append(QuarantinedRow(rowNumber: rowNumber, column: "weight_lbs", value: weightLbsRaw, message: "malformed weight_lbs"))
                continue
            }
            if !repsRaw.isEmpty && Int(repsRaw) == nil {
                quarantined.append(QuarantinedRow(rowNumber: rowNumber, column: "reps", value: repsRaw, message: "malformed reps"))
                continue
            }
            if !durationRaw.isEmpty && Int(durationRaw) == nil {
                quarantined.append(QuarantinedRow(rowNumber: rowNumber, column: "duration_seconds", value: durationRaw, message: "malformed duration_seconds"))
                continue
            }

            // BR-011: parsed-but-dropped metadata, counted.
            if !rpeRaw.isEmpty { counts.metadataDropped.rpe += 1 }
            if !exerciseNotesRaw.isEmpty { counts.metadataDropped.exerciseNotes += 1 }
            if !supersetRaw.isEmpty { counts.metadataDropped.supersetId += 1 }

            // BR-006: set_type is folded to completed at acceptance (counted
            // there, so collapsed duplicates never fold); validation only
            // normalizes the value.
            let setType = setTypeRaw.lowercased()

            let weightRaw: String
            switch declaredUnit {
            case .kg?: weightRaw = weightKgRaw
            case .lb?: weightRaw = weightLbsRaw
            case nil:  weightRaw = ""
            }

            validRows.append(ValidatedRow(
                rowNumber: rowNumber,
                title: title,
                description: description,
                startTime: startDate,
                startTimeISO: isoUTC(startDate),
                endTimeRaw: cell(record, "end_time").trimmingCharacters(in: .whitespacesAndNewlines),
                exerciseTitle: exerciseTitle,
                setIndexRaw: setIndexRaw,
                setType: setType,
                weightRaw: weightRaw,
                repsRaw: repsRaw,
                distanceKmRaw: distanceKmRaw,
                distanceMilesRaw: distanceMilesRaw,
                durationRaw: durationRaw
            ))
        }

        counts.quarantinedCount = quarantined.count

        // BR-012: >50% of non-empty data rows quarantined → abort, nothing written.
        let nonEmptyDataRows = counts.dataRows - counts.emptyRowsSkipped
        if quarantined.count * 2 > nonEmptyDataRows {
            throw HevyImportError.notHevyExport("majority of rows unparseable — doesn't look like a Hevy export")
        }

        // ---- Grouping + set mapping (BR-005/BR-006/BR-007/BR-008/BR-009/BR-010).
        final class SessionAccumulator {
            var importKey: String
            var displayTitle: String          // first-seen trimmed title
            var notes: String?                // first non-blank description, unescaped
            var endedAt: String?
            var setPlans: [ImportSetPlan] = []
            var seenDedupeKeys: Set<String> = []
            init(importKey: String, displayTitle: String) {
                self.importKey = importKey
                self.displayTitle = displayTitle
            }
        }
        var sessionOrder: [String] = []
        var sessionsByKey: [String: SessionAccumulator] = [:]
        var newExerciseOrder: [String] = []
        var newExercisesByName: [String: (displayName: String, durationMetric: Bool)] = [:]

        for row in validRows {
            let titleKey = row.title.lowercased()          // lower(trim(title)) — trim done above
            let sessionKey = titleKey + "|" + row.startTimeISO

            let acc: SessionAccumulator
            if let existing = sessionsByKey[sessionKey] {
                acc = existing
            } else {
                acc = SessionAccumulator(importKey: sessionKey, displayTitle: row.title)
                sessionsByKey[sessionKey] = acc
                sessionOrder.append(sessionKey)
            }
            // BR-005: notes from first non-blank description; endedAt from first
            // parseable non-blank end_time; both in file order.
            if acc.notes == nil && !row.description.isEmpty {
                acc.notes = HevyCsvParser.unescapeHevyNewlines(row.description)
            }
            if acc.endedAt == nil && !row.endTimeRaw.isEmpty,
               let endDate = parseHevyDateTime(row.endTimeRaw, offsetMinutes: options.timezoneOffsetMinutes) {
                acc.endedAt = isoUTC(endDate)
            }

            // BR-008: exact-duplicate collapse — first occurrence wins.
            let normEx = normalize(row.exerciseTitle)
            let dedupeKey = normEx + "\u{1}" + row.setIndexRaw
            if acc.seenDedupeKeys.contains(dedupeKey) {
                counts.duplicatesCollapsed += 1
                continue
            }
            acc.seenDedupeKeys.insert(dedupeKey)

            // BR-009: exercise resolution.
            let ref: ExerciseRef
            if let match = matchLibrary(normalized: normEx, library: library) {
                ref = .existing(match.id)
                counts.exercisesMatched += 1
            } else {
                ref = .new(normalizedName: normEx)
            }

            // BR-006 payload mapping.
            let reps = row.repsRaw.isEmpty ? nil : Int(row.repsRaw)
            let duration = row.durationRaw.isEmpty ? nil : Int(row.durationRaw)
            var actualWeight = row.weightRaw.isEmpty ? nil : Double(row.weightRaw)
            if let w = actualWeight, w == 0 { actualWeight = nil }   // bodyweight rule

            let isDurationSet = (reps == nil || reps == 0) && (duration ?? 0) > 0
            let hasDistance = !(row.distanceKmRaw.isEmpty && row.distanceMilesRaw.isEmpty)

            let setReps: Int?
            let setDuration: Int?
            if isDurationSet {
                setReps = nil
                setDuration = duration
            } else if let r = reps, r > 0 {
                setReps = r
                setDuration = nil
            } else if hasDistance {
                counts.cardioRowsSkipped += 1                 // BR-006: cardio, skipped + counted
                continue
            } else {
                quarantined.append(QuarantinedRow(
                    rowNumber: row.rowNumber, column: "reps/duration_seconds",
                    value: "", message: "no reps or duration payload"))
                counts.quarantinedCount += 1
                continue
            }

            // BR-009: register a new custom exercise ONLY once a row is actually
            // accepted as a set — cardio-skipped/quarantined rows never create one.
            if case .new = ref {
                if newExercisesByName[normEx] == nil {
                    newExerciseOrder.append(normEx)
                    newExercisesByName[normEx] = (displayName: displayForm(row.exerciseTitle), durationMetric: false)
                }
                if isDurationSet { newExercisesByName[normEx]?.durationMetric = true }
            }
            // BR-006: fold count applies to sets actually imported.
            if row.setType == "warmup" || row.setType == "failure" || row.setType == "dropset" {
                counts.foldedSetTypes += 1
            }

            // BR-010: effective unit → target-unit conversion at write time.
            if var w = actualWeight, let from = options.unitOverrides[normEx] ?? declaredUnit {
                if from != options.targetUnit {
                    w = (from == .kg) ? w * Self.lbPerKg : w * Self.kgPerLb
                    actualWeight = w
                }
            }

            // completedAt is session-level; backfilled after grouping (BR-006).
            acc.setPlans.append(ImportSetPlan(
                exerciseRef: ref,
                sortOrder: acc.setPlans.count,               // BR-007 file order, contiguous
                actualWeight: actualWeight,
                actualReps: setReps,
                actualDuration: setDuration,
                completedAt: ""                               // placeholder; finalized below
            ))
        }

        // ---- Assemble sessions in first-seen order.
        var sessionPlans: [ImportSessionPlan] = []
        for key in sessionOrder {
            guard let acc = sessionsByKey[key] else { continue }
            // BR-006: a session whose rows all skipped (cardio-only) imports nothing.
            if acc.setPlans.isEmpty { continue }
            // BR-006: per-set completedAt = session endedAt ?? startedAt.
            let resolvedCompletedAt = acc.endedAt ?? isoUTCFromKey(key)
            let sets = acc.setPlans.map { plan -> ImportSetPlan in
                var p = plan
                p.completedAt = resolvedCompletedAt
                return p
            }
            let alreadyImported = options.existingImportKeys.contains(key)
            if alreadyImported {
                counts.sessionsAlreadyImported += 1
            } else {
                counts.setsImported += sets.count
            }
            let name = acc.displayTitle.isEmpty ? untitledSessionName : acc.displayTitle
            sessionPlans.append(ImportSessionPlan(
                importKey: key,
                name: name,
                notes: acc.notes,
                startedAt: isoUTCFromKey(key),
                endedAt: acc.endedAt,
                sets: sets,
                alreadyImported: alreadyImported
            ))
        }
        counts.sessionsFound = sessionPlans.count

        let newExercises = newExerciseOrder.map { norm -> NewExercisePlan in
            let entry = newExercisesByName[norm]!
            return NewExercisePlan(
                name: entry.displayName,
                normalizedName: norm,
                metric: entry.durationMetric ? "duration" : "reps"
            )
        }

        return ImportPlan(
            unit: declaredUnit,
            now: options.now,
            sessions: sessionPlans,
            newExercises: newExercises,
            quarantined: quarantined,
            counts: counts,
            warnings: warnings
        )
    }

    // MARK: - Name handling (SC-exercises BR-001 parity; kept local so the
    // module stays GRDB-only-independent)

    /// `lowercase(trim(collapse_whitespace))`.
    public static func normalize(_ s: String) -> String {
        let parts = s.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return parts.joined(separator: " ")
    }

    /// Trim + collapse interior whitespace, case preserved (BR-009 storage name).
    public static func displayForm(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return parts.joined(separator: " ")
    }

    // MARK: - Exercise matching (BR-009)

    /// Hevy `(Equipment)` parenthetical → #3 equipmentSlug.
    public static func equipmentSlug(fromHevy label: String) -> String {
        switch label.lowercased() {
        case "barbell": return "barbell"
        case "dumbbell": return "dumbbell"
        case "cable": return "cable"
        case "machine": return "machine"
        case "bodyweight": return "bodyweight"
        case "smith machine": return "smith"
        case "plate": return "plate"
        case "band": return "band"
        case "kettlebell": return "kettlebell"
        case "ez bar": return "ezBar"
        case "trap bar": return "trapBar"
        case "medicine ball": return "medicineBall"
        case "sled": return "sled"
        default: return "other"
        }
    }

    /// Primary: exact normalized-name hit. Secondary: strip exactly one trailing
    /// `(Equipment)` parenthetical, match base name AND equipment compatibility.
    /// Candidates resolve built-ins first, then name ASC, then id ASC.
    public static func matchLibrary(normalized: String, library: [LibraryRow]) -> LibraryRow? {
        let primary = library.filter { $0.nameNormalized == normalized }
        if let head = sortCandidates(primary).first { return head }

        guard let (base, equipmentLabel) = stripTrailingParenthetical(normalized), base != normalized else {
            return nil
        }
        let wanted = equipmentSlug(fromHevy: equipmentLabel)
        let secondary = library.filter { row in
            row.nameNormalized == base
                && (row.equipmentSlug == nil || row.equipmentSlug == wanted)
        }
        return sortCandidates(secondary).first
    }

    private static func sortCandidates(_ rows: [LibraryRow]) -> [LibraryRow] {
        rows.sorted { a, b in
            if a.isCustom != b.isCustom { return !a.isCustom }   // built-ins first
            if a.name != b.name { return a.name < b.name }
            return a.id < b.id
        }
    }

    /// `"squat (barbell)" → ("squat", "barbell")`. Exactly one trailing group.
    public static func stripTrailingParenthetical(_ normalized: String) -> (base: String, label: String)? {
        guard let openIdx = normalized.lastIndex(of: "("),
              let closeIdx = normalized.lastIndex(of: ")"),
              openIdx < closeIdx,
              normalized[normalized.index(after: closeIdx)...].allSatisfy({ $0.isWhitespace })
        else { return nil }
        let base = String(normalized[..<openIdx]).trimmingCharacters(in: .whitespaces)
        let label = String(normalized[normalized.index(after: openIdx)..<closeIdx])
        guard !base.isEmpty else { return nil }
        return (base, label)
    }

    // MARK: - Datetime (BR-004)

    private static let monthIndex: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// `D Mon YYYY[, ]HH:MM[:SS]` naive wall-time → Date via fixed offset.
    /// Strict range validation (no calendar rollover): day within the month's
    /// length, hour 0–23, minute/second 0–59.
    public static func parseHevyDateTime(_ raw: String, offsetMinutes: Int) -> Date? {
        let pattern = #"^\s*(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s*,?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              match.numberOfRanges == 7
        else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: raw) else { return nil }
            return String(raw[r])
        }
        guard
            let dayStr = group(1), let monStr = group(2), let yearStr = group(3),
            let hourStr = group(4), let minStr = group(5),
            let day = Int(dayStr), let year = Int(yearStr),
            let hour = Int(hourStr), let minute = Int(minStr),
            let month = monthIndex[monStr.lowercased()]
        else { return nil }
        let second = group(6).flatMap(Int.init) ?? 0

        guard year >= 1900, year <= 2100 else { return nil }
        guard hour >= 0, hour <= 23, minute >= 0, minute <= 59, second >= 0, second <= 59 else { return nil }
        guard day >= 1, day <= daysInMonth(month: month, year: year) else { return nil }

        // Wall-time components in UTC, minus the local offset → absolute instant.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let utcWall = calendar.date(from: components) else { return nil }
        return utcWall.addingTimeInterval(TimeInterval(-offsetMinutes * 60))
    }

    private static func daysInMonth(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
            return leap ? 29 : 28
        }
    }

    /// BR-004 storage format: ISO-8601 UTC, second precision, `Z` suffix.
    public static func isoUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// importKey layout: `<lower(trim(title))>|<ISO-8601-UTC startedAt>`.
    private static func isoUTCFromKey(_ importKey: String) -> String {
        guard let bar = importKey.lastIndex(of: "|") else { return "" }
        return String(importKey[importKey.index(after: bar)...])
    }
}
