// contractId: SC-import @1.0.0
// §4 BR-002…BR-014 — the pure mapping layer. CSV text + library rows + options in,
// ImportPlan out. Seam-1: pure JVM, zero DB contact (INV-IM1). Byte-identical
// semantics across platforms per §9.
// Mechanical Kotlin port of Sources/MooreImport/HevyImportEngine.swift.
package com.moore.hevyimport

import java.time.Instant
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

// MARK: - Value types (§3b)

enum class HevyUnit(val raw: String) {
    KG("kg"), LB("lb");

    companion object {
        fun fromRaw(raw: String?): HevyUnit? = entries.firstOrNull { it.raw == raw }
    }
}

data class ImportOptions(
    var targetUnit: HevyUnit = HevyUnit.KG,            // BR-010; default kg
    var timezoneOffsetMinutes: Int = 0,                // BR-004/BR-017 device-local at import
    var now: String,                                   // ISO-8601 UTC write stamp
    var unitOverrides: Map<String, HevyUnit> = emptyMap(),   // BR-010 normalized name → unit
    var existingImportKeys: Set<String> = emptySet(),        // BR-013 DB probe
)

data class LibraryRow(
    var id: String,
    var name: String,
    var nameNormalized: String,
    var equipmentSlug: String?,
    var isCustom: Boolean,
)

data class QuarantinedRow(
    var rowNumber: Int,        // 1-based data-record index after the header record
    var column: String,
    var value: String,
    var message: String,
)

/// Set → exercise linkage: an existing row id, or a pending custom keyed by
/// normalized name (the DAO mints UUIDs at apply time, INV-IM8).
sealed class ExerciseRef {
    data class Existing(val id: String) : ExerciseRef()
    data class New(val normalizedName: String) : ExerciseRef()
}

data class ImportSetPlan(
    var exerciseRef: ExerciseRef,
    var sortOrder: Int,
    var actualWeight: Double?,
    var actualReps: Int?,
    var actualDuration: Int?,
    var completedAt: String,   // BR-006: session endedAt ?? startedAt
)

data class ImportSessionPlan(
    var importKey: String,
    var name: String,
    var notes: String?,
    var startedAt: String,     // ISO-8601 UTC, second precision
    var endedAt: String?,
    var sets: List<ImportSetPlan>,
    var alreadyImported: Boolean, // BR-013: excluded from apply, counted
)

data class NewExercisePlan(
    var name: String,            // displayForm, case preserved (BR-009)
    var normalizedName: String,
    var metric: String,          // "reps" | "duration" (BR-009/INV-IM8)
)

data class MetadataDroppedCounts(
    var rpe: Int = 0,
    var exerciseNotes: Int = 0,
    var supersetId: Int = 0,
)

data class PreviewCounts(
    var dataRows: Int = 0,
    var emptyRowsSkipped: Int = 0,
    var duplicatesCollapsed: Int = 0,
    var sessionsFound: Int = 0,
    var setsImported: Int = 0,
    var exercisesMatched: Int = 0,
    var sessionsAlreadyImported: Int = 0,
    var cardioRowsSkipped: Int = 0,
    var foldedSetTypes: Int = 0,
    var quarantinedCount: Int = 0,
    var metadataDropped: MetadataDroppedCounts = MetadataDroppedCounts(),
)

data class ImportPlan(
    var unit: HevyUnit?,
    var now: String,                 // write-metadata stamp from ImportOptions
    var sessions: List<ImportSessionPlan>,
    var newExercises: List<NewExercisePlan>,
    var quarantined: List<QuarantinedRow>,
    var counts: PreviewCounts,
    var warnings: List<String>,
)

sealed class HevyImportError(message: String) : Exception(message) {
    /// BR-002 missing headers / BR-012 >50% abort
    class NotHevyExport(message: String) : HevyImportError("notHevyExport: $message") {
        val code = "notHevyExport"
    }
    /// BR-001 parse failure
    class CsvMalformed(message: String) : HevyImportError("csvMalformed: $message") {
        val code = "csvMalformed"
    }
}

// MARK: - Engine

object HevyImportEngine {

    /// Untitled-session name fallback (BR-005; §6 hevyImport.untitledSession).
    const val untitledSessionName = "Imported workout"

    /// BR-010 conversion constants (SC-plate-calculator BR-005 parity).
    val kgPerLb = 1.0 / 2.20462
    const val lbPerKg = 2.20462

    /// Recognized columns (BR-002). Anything else is ignored (forward-compat).
    val recognizedColumns: Set<String> = setOf(
        "title", "start_time", "end_time", "description", "exercise_title",
        "superset_id", "exercise_notes", "set_index", "set_type",
        "weight_kg", "weight_lbs", "reps", "distance_km", "distance_miles",
        "duration_seconds", "rpe",
    )

    /// Strict numeric validation (mirrors Swift Int()/Double() parse failures).
    private val INT_RE = Regex("^[+-]?\\d+$")
    private val DOUBLE_RE = Regex("^[+-]?(\\d+(\\.\\d*)?|\\.\\d+)$")
    private fun parseStrictInt(s: String): Int? = if (INT_RE.matches(s)) s.toIntOrNull() else null
    private fun parseStrictDouble(s: String): Double? = if (DOUBLE_RE.matches(s)) s.toDoubleOrNull() else null

    /// Full-file pure plan build. Throws HevyImportError.NotHevyExport on
    /// missing required headers (BR-002) or the >50% quarantine abort (BR-012).
    fun buildPlan(
        csvText: String,
        library: List<LibraryRow>,
        options: ImportOptions,
    ): ImportPlan {
        val records: List<List<String>> = try {
            HevyCsvParser.parseRecords(csvText)
        } catch (e: HevyCsvError) {
            throw HevyImportError.CsvMalformed(e.message ?: e.toString())
        }
        val headerRecord = records.firstOrNull()
            ?: throw HevyImportError.NotHevyExport("empty file — no header record")

        // ---- Header map (BR-002): first occurrence wins, duplicates warn.
        val columnIndex = HashMap<String, Int>()
        val warnings = mutableListOf<String>()
        headerRecord.forEachIndexed { idx, raw ->
            val norm = HevyCsvParser.normalizeHeader(raw)
            if (norm !in recognizedColumns) return@forEachIndexed
            if (columnIndex.containsKey(norm)) {
                warnings.add("duplicate header '$norm' — first occurrence wins")
            } else {
                columnIndex[norm] = idx
            }
        }
        if (!columnIndex.containsKey("start_time") || !columnIndex.containsKey("exercise_title")) {
            throw HevyImportError.NotHevyExport("missing required header(s): start_time / exercise_title")
        }

        // ---- Declared unit (BR-010): presence of the weight column decides.
        val hasKg = columnIndex.containsKey("weight_kg")
        val hasLb = columnIndex.containsKey("weight_lbs")
        val declaredUnit: HevyUnit?
        if (hasKg && hasLb) {
            declaredUnit = HevyUnit.KG
            warnings.add("both weight_kg and weight_lbs present — kg wins")
        } else if (hasKg) {
            declaredUnit = HevyUnit.KG
        } else if (hasLb) {
            declaredUnit = HevyUnit.LB
        } else {
            declaredUnit = null
        }

        fun cell(record: List<String>, column: String): String {
            val idx = columnIndex[column] ?: return ""
            if (idx >= record.size) return ""
            return record[idx]
        }

        // ---- Row pass: validation, quarantine, metadata counts.
        val counts = PreviewCounts()
        val quarantined = mutableListOf<QuarantinedRow>()
        counts.dataRows = records.size - 1

        data class ValidatedRow(
            val rowNumber: Int,
            val title: String,              // trimmed raw (key uses lower(trim))
            val description: String,        // trimmed raw
            val startTimeMs: Long,
            val startTimeISO: String,
            val endTimeRaw: String,
            val exerciseTitle: String,      // trimmed raw
            val setIndexRaw: String,        // trimmed raw
            val setType: String,            // lowercased-trimmed
            val weightRaw: String,          // from the governing column
            val repsRaw: String,
            val distanceKmRaw: String,
            val distanceMilesRaw: String,
            val durationRaw: String,
        )
        val validRows = mutableListOf<ValidatedRow>()

        val dataRecords = records.drop(1)
        for ((index, record) in dataRecords.withIndex()) {
            val rowNumber = index + 1
            // BR-003: every cell blank-after-trim → skipped silently.
            if (record.all { it.trim().isEmpty() }) {
                counts.emptyRowsSkipped += 1
                continue
            }
            val title = cell(record, "title").trim()
            val startRaw = cell(record, "start_time").trim()
            val exerciseTitle = cell(record, "exercise_title").trim()
            val setIndexRaw = cell(record, "set_index").trim()
            val setTypeRaw = cell(record, "set_type").trim()
            val weightKgRaw = cell(record, "weight_kg").trim()
            val weightLbsRaw = cell(record, "weight_lbs").trim()
            val repsRaw = cell(record, "reps").trim()
            val distanceKmRaw = cell(record, "distance_km").trim()
            val distanceMilesRaw = cell(record, "distance_miles").trim()
            val durationRaw = cell(record, "duration_seconds").trim()
            val rpeRaw = cell(record, "rpe").trim()
            val exerciseNotesRaw = cell(record, "exercise_notes").trim()
            val supersetRaw = cell(record, "superset_id").trim()
            val description = cell(record, "description").trim()

            // BR-004: start_time is the identity carrier; failure quarantines.
            val startMs = parseHevyDateTime(startRaw, options.timezoneOffsetMinutes)
            if (startMs == null) {
                quarantined.add(QuarantinedRow(rowNumber, "start_time", startRaw, "unparseable start_time"))
                continue
            }
            // BR-012(b): blank exercise_title.
            if (exerciseTitle.isEmpty()) {
                quarantined.add(QuarantinedRow(rowNumber, "exercise_title", "", "blank exercise_title"))
                continue
            }
            // BR-012(c): malformed numerics.
            if (setIndexRaw.isNotEmpty() && parseStrictInt(setIndexRaw) == null) {
                quarantined.add(QuarantinedRow(rowNumber, "set_index", setIndexRaw, "malformed set_index"))
                continue
            }
            if (weightKgRaw.isNotEmpty() && parseStrictDouble(weightKgRaw) == null) {
                quarantined.add(QuarantinedRow(rowNumber, "weight_kg", weightKgRaw, "malformed weight_kg"))
                continue
            }
            if (weightLbsRaw.isNotEmpty() && parseStrictDouble(weightLbsRaw) == null) {
                quarantined.add(QuarantinedRow(rowNumber, "weight_lbs", weightLbsRaw, "malformed weight_lbs"))
                continue
            }
            if (repsRaw.isNotEmpty() && parseStrictInt(repsRaw) == null) {
                quarantined.add(QuarantinedRow(rowNumber, "reps", repsRaw, "malformed reps"))
                continue
            }
            if (durationRaw.isNotEmpty() && parseStrictInt(durationRaw) == null) {
                quarantined.add(QuarantinedRow(rowNumber, "duration_seconds", durationRaw, "malformed duration_seconds"))
                continue
            }

            // BR-011: parsed-but-dropped metadata, counted.
            if (rpeRaw.isNotEmpty()) counts.metadataDropped.rpe += 1
            if (exerciseNotesRaw.isNotEmpty()) counts.metadataDropped.exerciseNotes += 1
            if (supersetRaw.isNotEmpty()) counts.metadataDropped.supersetId += 1

            // BR-006: set_type is folded to completed at acceptance (counted
            // there, so collapsed duplicates never fold); validation only
            // normalizes the value.
            val setType = setTypeRaw.lowercase()

            val weightRaw: String = when (declaredUnit) {
                HevyUnit.KG -> weightKgRaw
                HevyUnit.LB -> weightLbsRaw
                null -> ""
            }

            validRows.add(ValidatedRow(
                rowNumber = rowNumber,
                title = title,
                description = description,
                startTimeMs = startMs,
                startTimeISO = isoUTC(startMs),
                endTimeRaw = cell(record, "end_time").trim(),
                exerciseTitle = exerciseTitle,
                setIndexRaw = setIndexRaw,
                setType = setType,
                weightRaw = weightRaw,
                repsRaw = repsRaw,
                distanceKmRaw = distanceKmRaw,
                distanceMilesRaw = distanceMilesRaw,
                durationRaw = durationRaw,
            ))
        }

        counts.quarantinedCount = quarantined.size

        // BR-012: >50% of non-empty data rows quarantined → abort, nothing written.
        val nonEmptyDataRows = counts.dataRows - counts.emptyRowsSkipped
        if (quarantined.size * 2 > nonEmptyDataRows) {
            throw HevyImportError.NotHevyExport("majority of rows unparseable — doesn't look like a Hevy export")
        }

        // ---- Grouping + set mapping (BR-005..BR-010).
        class SessionAccumulator(var importKey: String, var displayTitle: String) {
            var notes: String? = null                // first non-blank description, unescaped
            var endedAt: String? = null
            val setPlans = mutableListOf<ImportSetPlan>()
            val seenDedupeKeys = HashSet<String>()
        }
        val sessionOrder = mutableListOf<String>()
        val sessionsByKey = HashMap<String, SessionAccumulator>()
        val newExerciseOrder = mutableListOf<String>()
        data class NewExerciseAcc(var displayName: String, var durationMetric: Boolean)
        val newExercisesByName = HashMap<String, NewExerciseAcc>()

        for (row in validRows) {
            val titleKey = row.title.lowercase()          // lower(trim(title)) — trim done above
            val sessionKey = titleKey + "|" + row.startTimeISO

            val acc = sessionsByKey.getOrPut(sessionKey) {
                val created = SessionAccumulator(importKey = sessionKey, displayTitle = row.title)
                sessionOrder.add(sessionKey)
                created
            }
            // BR-005: notes from first non-blank description; endedAt from first
            // parseable non-blank end_time; both in file order.
            if (acc.notes == null && row.description.isNotEmpty()) {
                acc.notes = HevyCsvParser.unescapeHevyNewlines(row.description)
            }
            if (acc.endedAt == null && row.endTimeRaw.isNotEmpty()) {
                val endMs = parseHevyDateTime(row.endTimeRaw, options.timezoneOffsetMinutes)
                if (endMs != null) acc.endedAt = isoUTC(endMs)
            }

            // BR-008: exact-duplicate collapse — first occurrence wins.
            val normEx = normalize(row.exerciseTitle)
            val dedupeKey = normEx + "\u0001" + row.setIndexRaw
            if (acc.seenDedupeKeys.contains(dedupeKey)) {
                counts.duplicatesCollapsed += 1
                continue
            }
            acc.seenDedupeKeys.add(dedupeKey)

            // BR-009: exercise resolution.
            val match = matchLibrary(normEx, library)
            val ref: ExerciseRef
            if (match != null) {
                ref = ExerciseRef.Existing(match.id)
                counts.exercisesMatched += 1
            } else {
                ref = ExerciseRef.New(normalizedName = normEx)
            }

            // BR-006 payload mapping.
            val reps = if (row.repsRaw.isEmpty()) null else parseStrictInt(row.repsRaw)
            val duration = if (row.durationRaw.isEmpty()) null else parseStrictInt(row.durationRaw)
            var actualWeight = if (row.weightRaw.isEmpty()) null else parseStrictDouble(row.weightRaw)
            if (actualWeight == 0.0) actualWeight = null   // bodyweight rule

            val isDurationSet = (reps == null || reps == 0) && (duration ?: 0) > 0
            val hasDistance = !(row.distanceKmRaw.isEmpty() && row.distanceMilesRaw.isEmpty())

            val setReps: Int?
            val setDuration: Int?
            if (isDurationSet) {
                setReps = null
                setDuration = duration
            } else if (reps != null && reps > 0) {
                setReps = reps
                setDuration = null
            } else if (hasDistance) {
                counts.cardioRowsSkipped += 1                 // BR-006: cardio, skipped + counted
                continue
            } else {
                quarantined.add(QuarantinedRow(
                    row.rowNumber, "reps/duration_seconds",
                    "", "no reps or duration payload"))
                counts.quarantinedCount += 1
                continue
            }

            // BR-009: register a new custom exercise ONLY once a row is actually
            // accepted as a set — cardio-skipped/quarantined rows never create one.
            if (ref is ExerciseRef.New) {
                if (!newExercisesByName.containsKey(normEx)) {
                    newExerciseOrder.add(normEx)
                    newExercisesByName[normEx] = NewExerciseAcc(displayForm(row.exerciseTitle), false)
                }
                if (isDurationSet) newExercisesByName[normEx]?.durationMetric = true
            }
            // BR-006: fold count applies to sets actually imported.
            if (row.setType == "warmup" || row.setType == "failure" || row.setType == "dropset") {
                counts.foldedSetTypes += 1
            }

            // BR-010: effective unit → target-unit conversion at write time.
            var w = actualWeight
            val from = options.unitOverrides[normEx] ?: declaredUnit
            if (w != null && from != null) {
                if (from != options.targetUnit) {
                    w = if (from == HevyUnit.KG) w * lbPerKg else w * kgPerLb
                }
            }
            actualWeight = w

            // completedAt is session-level; backfilled after grouping (BR-006).
            acc.setPlans.add(ImportSetPlan(
                exerciseRef = ref,
                sortOrder = acc.setPlans.size,               // BR-007 file order, contiguous
                actualWeight = actualWeight,
                actualReps = setReps,
                actualDuration = setDuration,
                completedAt = "",                            // placeholder; finalized below
            ))
        }

        // ---- Assemble sessions in first-seen order.
        val sessionPlans = mutableListOf<ImportSessionPlan>()
        for (key in sessionOrder) {
            val acc = sessionsByKey[key] ?: continue
            // BR-006: a session whose rows all skipped (cardio-only) imports nothing.
            if (acc.setPlans.isEmpty()) continue
            // BR-006: per-set completedAt = session endedAt ?? startedAt.
            val resolvedCompletedAt = acc.endedAt ?: isoUTCFromKey(key)
            val sets = acc.setPlans.map { plan -> plan.copy(completedAt = resolvedCompletedAt) }
            val alreadyImported = options.existingImportKeys.contains(key)
            if (alreadyImported) {
                counts.sessionsAlreadyImported += 1
            } else {
                counts.setsImported += sets.size
            }
            val name = if (acc.displayTitle.isEmpty()) untitledSessionName else acc.displayTitle
            sessionPlans.add(ImportSessionPlan(
                importKey = key,
                name = name,
                notes = acc.notes,
                startedAt = isoUTCFromKey(key),
                endedAt = acc.endedAt,
                sets = sets,
                alreadyImported = alreadyImported,
            ))
        }
        counts.sessionsFound = sessionPlans.size

        val newExercises = newExerciseOrder.map { norm ->
            val entry = newExercisesByName.getValue(norm)
            NewExercisePlan(
                name = entry.displayName,
                normalizedName = norm,
                metric = if (entry.durationMetric) "duration" else "reps",
            )
        }

        return ImportPlan(
            unit = declaredUnit,
            now = options.now,
            sessions = sessionPlans,
            newExercises = newExercises,
            quarantined = quarantined,
            counts = counts,
            warnings = warnings,
        )
    }

    // MARK: - Name handling (SC-exercises BR-001 parity)

    /// lowercase(trim(collapse_whitespace)).
    fun normalize(s: String): String {
        val parts = s.lowercase().trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        return parts.joinToString(" ")
    }

    /// Trim + collapse interior whitespace, case preserved (BR-009 storage name).
    fun displayForm(s: String): String {
        val parts = s.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        return parts.joinToString(" ")
    }

    // MARK: - Exercise matching (BR-009)

    /// Hevy `(Equipment)` parenthetical → #3 equipmentSlug.
    fun equipmentSlugFromHevy(label: String): String {
        return when (label.lowercase()) {
            "barbell" -> "barbell"
            "dumbbell" -> "dumbbell"
            "cable" -> "cable"
            "machine" -> "machine"
            "bodyweight" -> "bodyweight"
            "smith machine" -> "smith"
            "plate" -> "plate"
            "band" -> "band"
            "kettlebell" -> "kettlebell"
            "ez bar" -> "ezBar"
            "trap bar" -> "trapBar"
            "medicine ball" -> "medicineBall"
            "sled" -> "sled"
            else -> "other"
        }
    }

    /// Primary: exact normalized-name hit. Secondary: strip exactly one trailing
    /// `(Equipment)` parenthetical, match base name AND equipment compatibility.
    /// Candidates resolve built-ins first, then name ASC, then id ASC.
    fun matchLibrary(normalized: String, library: List<LibraryRow>): LibraryRow? {
        val primary = library.filter { it.nameNormalized == normalized }
        primary.firstOrNull()?.let { return sortCandidates(primary).first() }

        val stripped = stripTrailingParenthetical(normalized)
        if (stripped == null || stripped.first == normalized) return null
        val (base, equipmentLabel) = stripped
        val wanted = equipmentSlugFromHevy(equipmentLabel)
        val secondary = library.filter { row ->
            row.nameNormalized == base &&
                (row.equipmentSlug == null || row.equipmentSlug == wanted)
        }
        return sortCandidates(secondary).firstOrNull()
    }

    private fun sortCandidates(rows: List<LibraryRow>): List<LibraryRow> {
        return rows.sortedWith(compareBy<LibraryRow> { it.isCustom }
            .thenBy { it.name }
            .thenBy { it.id })
    }

    /// "squat (barbell)" → ("squat", "barbell"). Exactly one trailing group.
    fun stripTrailingParenthetical(normalized: String): Pair<String, String>? {
        val openIdx = normalized.lastIndexOf('(')
        val closeIdx = normalized.lastIndexOf(')')
        if (openIdx < 0 || closeIdx < 0 || openIdx >= closeIdx) return null
        if (normalized.substring(closeIdx + 1).trim().isNotEmpty()) return null
        val base = normalized.substring(0, openIdx).trim()
        val label = normalized.substring(openIdx + 1, closeIdx)
        if (base.isEmpty()) return null
        return base to label
    }

    // MARK: - Datetime (BR-004)

    private val monthIndex = mapOf(
        "jan" to 1, "feb" to 2, "mar" to 3, "apr" to 4, "may" to 5, "jun" to 6,
        "jul" to 7, "aug" to 8, "sep" to 9, "oct" to 10, "nov" to 11, "dec" to 12,
    )

    private val HEVY_DATE_RE = Regex(
        "^\\s*(\\d{1,2})\\s+([A-Za-z]{3})\\s+(\\d{4})\\s*,?\\s+(\\d{1,2}):(\\d{2})(?::(\\d{2}))?\\s*$"
    )

    /// `D Mon YYYY[, ]HH:MM[:SS]` naive wall-time → epoch millis via fixed offset.
    /// Strict range validation (no calendar rollover): day within the month's
    /// length, hour 0–23, minute/second 0–59.
    fun parseHevyDateTime(raw: String, offsetMinutes: Int): Long? {
        val match = HEVY_DATE_RE.matchEntire(raw) ?: return null
        val day = match.groupValues[1].toIntOrNull() ?: return null
        val monStr = match.groupValues[2]
        val year = match.groupValues[3].toIntOrNull() ?: return null
        val hour = match.groupValues[4].toIntOrNull() ?: return null
        val minute = match.groupValues[5].toIntOrNull() ?: return null
        val second = if (match.groupValues[6].isEmpty()) 0 else match.groupValues[6].toIntOrNull() ?: return null
        val month = monthIndex[monStr.lowercase()] ?: return null

        if (year < 1900 || year > 2100) return null
        if (hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) return null
        if (day < 1 || day > daysInMonth(month, year)) return null

        // Wall-time components in UTC, minus the local offset → absolute instant.
        val utcWallMs = ZonedDateTime.of(year, month, day, hour, minute, second, 0, ZoneOffset.UTC)
            .toInstant().toEpochMilli()
        return utcWallMs - offsetMinutes.toLong() * 60_000L
    }

    private fun daysInMonth(month: Int, year: Int): Int {
        return when (month) {
            1, 3, 5, 7, 8, 10, 12 -> 31
            4, 6, 9, 11 -> 30
            else -> {
                val leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
                if (leap) 29 else 28
            }
        }
    }

    private val ISO_UTC_FORMAT: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)

    /// BR-004 storage format: ISO-8601 UTC, second precision, Z suffix.
    fun isoUTC(epochMillis: Long): String = ISO_UTC_FORMAT.format(Instant.ofEpochMilli(epochMillis))

    /// importKey layout: `<lower(trim(title))>|<ISO-8601-UTC startedAt>`.
    private fun isoUTCFromKey(importKey: String): String {
        val bar = importKey.lastIndexOf('|')
        if (bar < 0) return ""
        return importKey.substring(bar + 1)
    }
}
