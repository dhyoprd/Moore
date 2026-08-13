// contractId: SC-analytics @1.0.0
// §5 seam-1 engine: pure, closed-form derivations over read inputs. No I/O, no
// state. Every analytics value recomputes from CompletedSet + WorkoutSession +
// Exercise + PersonalRecord at read time — analytics is never persisted (INV-A1).
//
// All calendar math is UTC-day based (BR-009/INV-A4): an ISO-8601 UTC timestamp's
// calendar day is its leading "YYYY-MM-DD". Day arithmetic uses the closed-form
// days-from-civil algorithm so every platform mirror is byte-identical.
// Mechanical Kotlin port of Sources/MooreAnalytics/AnalyticsEngine.swift.
package com.moore.analytics

// MARK: - Read-model value types

data class AnalyticsSession(
    var id: String,
    var name: String?,
    var startedAt: String,            // ISO-8601 UTC
    var endedAt: String?,
)

data class AnalyticsSet(
    var id: String,
    var sessionId: String,
    var exerciseId: String,
    var sortOrder: Int,
    var plannedWeight: Double? = null,
    var plannedReps: Int? = null,
    var plannedDuration: Int? = null,
    var actualWeight: Double? = null,
    var actualReps: Int? = null,
    var actualDuration: Int? = null,
    var status: String,               // planned|completed|failed|dropped
    var setClass: String? = null,     // null ⇔ 'work' (SC-foundation INV-6)
    var completedAt: String? = null,
)

data class ExerciseInfo(
    var id: String,
    var name: String,
    var category: String?,            // SC-exercises §3b enum; NULL = unclassified
)

/// personal_record post-0009, live rows only.
data class PRRow(
    var id: String,
    var exerciseId: String,
    var sessionId: String,
    var kind: String,
    var value: Double,
    var achievedAt: String,
)

// MARK: - Output shapes

data class TrendPoint(
    var day: String,
    var value: Double,
    var segment: Int,                 // increments when gap to previous point > gapBreakDays (BR-002)
)

data class WeekTonnage(
    var week: String,                 // ISO week key "YYYY-Www"
    var tonnage: Double,
)

data class MuscleBucket(
    var bucket: String,               // upper|lower|other (BR-004)
    var tonnage: Double,
    var pct: Double,                  // unrounded; sums to 100 within float epsilon
)

data class PRListItem(
    var id: String,
    var exerciseId: String,
    var exerciseName: String,
    var kind: String,
    var sessionId: String,
    var achievedAt: String,
    var day: String,
    var value: Double,
)

data class HistoryRow(
    var sessionId: String,
    var name: String?,
    var day: String,
    var startedAt: String,
    var completedCount: Int,
    var tonnage: Double,
    var prCount: Int,                 // > 0 ⇒ history.badge.pr renders (SC-prs §6)
)

data class HistoryMonth(
    var month: String,                // "YYYY-MM"
    var rows: List<HistoryRow>,
)

data class PlanActualRow(
    var setId: String,
    var exerciseId: String,
    var sortOrder: Int,
    var status: String,
    var setClass: String?,
    var plannedWeight: Double?,
    var plannedReps: Int?,
    var plannedDuration: Int?,
    var actualWeight: Double?,
    var actualReps: Int?,
    var actualDuration: Int?,
)

data class AdherenceHeader(
    var sessionsLast7: Int,
    var sessionsLast30: Int,
    var currentStreak: Int,
)

// MARK: - Engine

object AnalyticsEngine {

    // MARK: Closed-form UTC day/week math

    /// UTC calendar day of an ISO-8601 UTC timestamp: the leading "YYYY-MM-DD".
    fun utcDay(iso: String): String = iso.take(10)

    /// Days since 1970-01-01 for a "YYYY-MM-DD" day (Howard Hinnant days_from_civil;
    /// proleptic Gregorian). A malformed day maps to 0 rather than trapping.
    fun dayNumber(day: String): Int {
        val parts = day.split("-").mapNotNull { it.toIntOrNull() }
        if (parts.size != 3) return 0
        return daysFromCivil(parts[0], parts[1], parts[2])
    }

    internal fun daysFromCivil(year: Int, month: Int, day: Int): Int {
        var y = year
        if (month <= 2) y -= 1
        val era = (if (y >= 0) y else y - 399) / 400
        val yoe = y - era * 400                                   // [0, 399]
        val doy = (153 * (month + if (month > 2) -3 else 9) + 2) / 5 + day - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// Inverse of daysFromCivil → (year, month, day) (civil_from_days).
    internal fun civilFromDayNumber(z: Int): Triple<Int, Int, Int> {
        val zs = z + 719468
        val era = (if (zs >= 0) zs else zs - 146096) / 146097
        val doe = zs - era * 146097                               // [0, 146096]
        val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        val y = yoe + era * 400
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val d = doy - (153 * mp + 2) / 5 + 1
        val m = if (mp < 10) mp + 3 else mp - 9
        return Triple(if (m <= 2) y + 1 else y, m, d)
    }

    /// "YYYY-MM-DD" for a day number.
    internal fun dayString(dayNumber: Int): String {
        val (y, m, d) = civilFromDayNumber(dayNumber)
        return "%04d-%02d-%02d".format(y, m, d)
    }

    /// Monday-indexed weekday of a day number: Mon=0 … Sun=6. 1970-01-01 (day 0)
    /// was a Thursday.
    internal fun mondayIndex(dayNumber: Int): Int {
        val thu0 = ((dayNumber % 7) + 7) % 7                      // 0 = Thursday
        return (thu0 + 3) % 7
    }

    /// ISO-8601 week key "YYYY-Www": weeks start Monday; the week containing Jan 4
    /// is W01; the key's year is the year of the week's Thursday.
    fun isoWeekKey(day: String): String {
        val dn = dayNumber(day)
        val thursday = dn + (3 - mondayIndex(dn))
        val isoYear = civilFromDayNumber(thursday).first
        val jan4 = daysFromCivil(isoYear, 1, 4)
        val week1Thursday = jan4 + (3 - mondayIndex(jan4))
        val week = (thursday - week1Thursday) / 7 + 1
        return "%04d-W%02d".format(isoYear, week)
    }

    /// Epley estimated 1RM: weight × (1 + reps/30), unrounded (SC-prs §3b).
    fun epley1RM(weight: Double, reps: Int): Double = weight * (1.0 + reps.toDouble() / 30.0)

    /// INV-6: NULL setClass coalesces to work; only 'warmup' is excluded.
    internal fun isWorkClass(setClass: String?): Boolean = (setClass ?: "work") == "work"

    /// Day → session window filter (INV-A4): inclusive [today − (rangeDays − 1), today].
    internal fun sessionDaysInWindow(today: String, rangeDays: Int, sessions: List<AnalyticsSession>): Map<String, String> {
        val hi = dayNumber(today)
        val lo = hi - (rangeDays - 1)
        val out = HashMap<String, String>()
        for (s in sessions) {
            val day = utcDay(s.startedAt)
            val dn = dayNumber(day)
            if (dn >= lo && dn <= hi) out[s.id] = day
        }
        return out
    }

    // MARK: BR-001 — streak + adherence header

    /// Days carrying ≥1 live set with logged actuals that was not dropped:
    /// status ∈ {completed, failed}. Sorted ascending.
    fun qualifyingDays(sessions: List<AnalyticsSession>, sets: List<AnalyticsSet>): List<String> {
        val dayBySession = HashMap<String, String>()
        for (s in sessions) dayBySession[s.id] = utcDay(s.startedAt)
        val days = mutableSetOf<String>()
        for (set in sets) {
            if (set.status == "completed" || set.status == "failed") {
                dayBySession[set.sessionId]?.let { days.add(it) }
            }
        }
        return days.sorted()
    }

    /// Consecutive qualifying days ending at the anchor: today if it qualifies,
    /// else yesterday; 0 when neither qualifies (BR-001).
    fun currentStreak(qualifyingDays: List<String>, today: String): Int {
        val days = qualifyingDays.toSet()
        if (days.isEmpty()) return 0
        var anchor = dayNumber(today)
        if (!days.contains(dayString(anchor))) {
            anchor -= 1                                           // yesterday keeps a live streak alive
            if (!days.contains(dayString(anchor))) return 0
        }
        var count = 0
        var cursor = anchor
        while (days.contains(dayString(cursor))) {
            count += 1
            cursor -= 1
        }
        return count
    }

    /// BR-010 session counts + BR-001 streak in one header read.
    fun adherenceHeader(sessions: List<AnalyticsSession>, sets: List<AnalyticsSet>, today: String): AdherenceHeader {
        val todayNum = dayNumber(today)
        fun countWithin(n: Int): Int {
            val lo = todayNum - (n - 1)
            return sessions.count { s ->
                val dn = dayNumber(utcDay(s.startedAt))
                dn >= lo && dn <= todayNum
            }
        }
        return AdherenceHeader(
            sessionsLast7 = countWithin(7),
            sessionsLast30 = countWithin(30),
            currentStreak = currentStreak(qualifyingDays(sessions, sets), today),
        )
    }

    // MARK: BR-002 — Epley 1RM trend

    /// One point per session/day with ≥1 qualifying set for the exercise
    /// (completed work sets with weight>0, reps>0); value = max Epley over the
    /// day's qualifying sets; gap > gapBreakDays days between consecutive points
    /// starts a new segment. Windowed by [today − (rangeDays − 1), today].
    fun epleyTrend(
        sessions: List<AnalyticsSession>,
        sets: List<AnalyticsSet>,
        exerciseId: String,
        today: String,
        rangeDays: Int,
        gapBreakDays: Int = 7,
    ): List<TrendPoint> {
        val window = sessionDaysInWindow(today, rangeDays, sessions)
        val bestByDay = HashMap<String, Double>()
        for (set in sets) {
            if (set.exerciseId != exerciseId) continue
            if (set.status != "completed" || !isWorkClass(set.setClass)) continue
            val day = window[set.sessionId] ?: continue
            val w = set.actualWeight
            val r = set.actualReps
            if (w == null || w <= 0 || r == null || r <= 0) continue
            val v = epley1RM(w, r)
            val cur = bestByDay[day]
            bestByDay[day] = if (cur != null) maxOf(cur, v) else v
        }
        val points = mutableListOf<TrendPoint>()
        var segment = 0
        var prevDayNum: Int? = null
        for (day in bestByDay.keys.sorted()) {
            val dn = dayNumber(day)
            val prev = prevDayNum
            if (prev != null && dn - prev > gapBreakDays) segment += 1
            points.add(TrendPoint(day, bestByDay[day] ?: 0.0, segment))
            prevDayNum = dn
        }
        return points
    }

    // MARK: BR-003 — weekly tonnage (warmups excluded)

    /// Σ actualWeight×actualReps per ISO week over completed non-warmup sets with
    /// both actuals present; weeks with zero volume are absent (INV-A3).
    fun weeklyTonnage(
        sessions: List<AnalyticsSession>,
        sets: List<AnalyticsSet>,
        today: String,
        rangeDays: Int,
    ): List<WeekTonnage> {
        val window = sessionDaysInWindow(today, rangeDays, sessions)
        val byWeek = HashMap<String, Double>()
        for (set in sets) {
            if (set.status != "completed" || (set.setClass ?: "work") == "warmup") continue
            val day = window[set.sessionId] ?: continue
            val w = set.actualWeight ?: continue
            val r = set.actualReps ?: continue
            val week = isoWeekKey(day)
            byWeek[week] = (byWeek[week] ?: 0.0) + w * r.toDouble()
        }
        return byWeek.keys.sorted().map { WeekTonnage(it, byWeek[it] ?: 0.0) }
    }

    // MARK: BR-004 — muscle split

    val upperCategories: Set<String> = setOf("chest", "back", "shoulders", "biceps", "triceps", "forearms")
    val lowerCategories: Set<String> = setOf("quads", "hamstrings", "glutes", "calves")

    /// Bucket for an exercise category: upper/lower per the BR-004 maps;
    /// everything else (core, fullBody, cardio, other, NULL) → other.
    fun bucketForCategory(category: String?): String {
        val c = category ?: return "other"
        if (c in upperCategories) return "upper"
        if (c in lowerCategories) return "lower"
        return "other"
    }

    /// Non-zero buckets in fixed order upper, lower, other with unrounded pct.
    fun muscleSplit(
        sessions: List<AnalyticsSession>,
        sets: List<AnalyticsSet>,
        exercises: List<ExerciseInfo>,
        today: String,
        rangeDays: Int,
    ): List<MuscleBucket> {
        val categoryById = HashMap<String, String?>()
        for (e in exercises) categoryById[e.id] = e.category
        val window = sessionDaysInWindow(today, rangeDays, sessions)
        val byBucket = HashMap<String, Double>()
        for (set in sets) {
            if (set.status != "completed" || !isWorkClass(set.setClass)) continue
            val day = window[set.sessionId] ?: continue
            val w = set.actualWeight ?: continue
            val r = set.actualReps ?: continue
            val bucket = bucketForCategory(categoryById[set.exerciseId])
            byBucket[bucket] = (byBucket[bucket] ?: 0.0) + w * r.toDouble()
        }
        val total = byBucket.values.sum()
        if (total <= 0) return emptyList()
        return listOf("upper", "lower", "other").mapNotNull { name ->
            val t = byBucket[name]
            if (t == null || t <= 0) null else MuscleBucket(name, t, t / total * 100.0)
        }
    }

    // MARK: BR-005 — PR list

    /// Reverse-chronological live PRs; deterministic tie-break exerciseId, kind.
    /// Names resolve including tombstoned exercises (INV-L3).
    fun prList(rows: List<PRRow>, exercises: List<ExerciseInfo>): List<PRListItem> {
        val nameById = HashMap<String, String>()
        for (e in exercises) nameById[e.id] = e.name
        return rows
            .sortedWith(compareBy<PRRow> { it.achievedAt }.reversed()
                .thenBy { it.exerciseId }
                .thenBy { it.kind })
            .map { row ->
                PRListItem(
                    id = row.id,
                    exerciseId = row.exerciseId,
                    exerciseName = nameById[row.exerciseId] ?: "",
                    kind = row.kind,
                    sessionId = row.sessionId,
                    achievedAt = row.achievedAt,
                    day = utcDay(row.achievedAt),
                    value = row.value,
                )
            }
    }

    // MARK: BR-006 — History

    /// Month-grouped sessions: months descending, rows startedAt-descending within
    /// a month (tie-break id). Row tonnage uses BR-003's gate; prCount is the live
    /// personal_record row count for the session (badge probe, SC-prs §3a).
    fun history(
        sessions: List<AnalyticsSession>,
        sets: List<AnalyticsSet>,
        prs: List<PRRow>,
    ): List<HistoryMonth> {
        val setsBySession = HashMap<String, MutableList<AnalyticsSet>>()
        for (set in sets) setsBySession.getOrPut(set.sessionId) { mutableListOf() }.add(set)
        val prCountBySession = HashMap<String, Int>()
        for (pr in prs) prCountBySession[pr.sessionId] = (prCountBySession[pr.sessionId] ?: 0) + 1

        val rowsByMonth = HashMap<String, MutableList<HistoryRow>>()
        for (session in sessions) {
            val day = utcDay(session.startedAt)
            val month = day.take(7)
            val sessionSets = setsBySession[session.id] ?: emptyList()
            var tonnage = 0.0
            var completedCount = 0
            for (set in sessionSets) {
                if (set.status != "completed") continue
                completedCount += 1
                val w = set.actualWeight
                val r = set.actualReps
                if (isWorkClass(set.setClass) && w != null && r != null) {
                    tonnage += w * r.toDouble()
                }
            }
            rowsByMonth.getOrPut(month) { mutableListOf() }.add(HistoryRow(
                sessionId = session.id,
                name = session.name,
                day = day,
                startedAt = session.startedAt,
                completedCount = completedCount,
                tonnage = tonnage,
                prCount = prCountBySession[session.id] ?: 0,
            ))
        }
        return rowsByMonth.keys.sortedDescending().map { month ->
            val rows = (rowsByMonth[month] ?: emptyList()).sortedWith(
                compareBy<HistoryRow> { it.startedAt }.reversed().thenBy { it.sessionId })
            HistoryMonth(month, rows)
        }
    }

    // MARK: BR-007 — session detail (plan-vs-actual)

    /// The session's sets in sortOrder with the dual planned/actual columns intact
    /// (INV-5). Failed rows keep their recorded actuals (SC-workout-logging BR-002).
    fun sessionDetailRows(sessionId: String, sets: List<AnalyticsSet>): List<PlanActualRow> {
        return sets
            .filter { it.sessionId == sessionId }
            .sortedWith(compareBy<AnalyticsSet> { it.sortOrder }.thenBy { it.id })
            .map { s ->
                PlanActualRow(
                    setId = s.id,
                    exerciseId = s.exerciseId,
                    sortOrder = s.sortOrder,
                    status = s.status,
                    setClass = s.setClass,
                    plannedWeight = s.plannedWeight,
                    plannedReps = s.plannedReps,
                    plannedDuration = s.plannedDuration,
                    actualWeight = s.actualWeight,
                    actualReps = s.actualReps,
                    actualDuration = s.actualDuration,
                )
            }
    }
}
