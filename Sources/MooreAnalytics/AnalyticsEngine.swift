// contractId: SC-analytics @1.0.0
// §5 seam-1 engine: pure, closed-form derivations over read inputs. No I/O, no
// state, Foundation only. Every analytics value recomputes from CompletedSet +
// WorkoutSession + Exercise + PersonalRecord at read time — analytics is never
// persisted (INV-A1; #3 invariant 5; SC-foundation §3c).
//
// All calendar math is UTC-day based (BR-009/INV-A4): an ISO-8601 UTC timestamp's
// calendar day is its leading "YYYY-MM-DD". Day arithmetic uses the closed-form
// days-from-civil algorithm so the JS verifier can mirror it byte-identically.

import Foundation

// MARK: - Read-model value types

public struct AnalyticsSession: Equatable, Sendable {
    public var id: String
    public var name: String?
    public var startedAt: String            // ISO-8601 UTC
    public var endedAt: String?

    public init(id: String, name: String?, startedAt: String, endedAt: String?) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct AnalyticsSet: Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var exerciseId: String
    public var sortOrder: Int
    public var plannedWeight: Double?
    public var plannedReps: Int?
    public var plannedDuration: Int?
    public var actualWeight: Double?
    public var actualReps: Int?
    public var actualDuration: Int?
    public var status: String               // planned|completed|failed|dropped
    public var setClass: String?            // nil ⇔ 'work' (SC-foundation INV-6)
    public var completedAt: String?

    public init(
        id: String, sessionId: String, exerciseId: String, sortOrder: Int,
        plannedWeight: Double? = nil, plannedReps: Int? = nil, plannedDuration: Int? = nil,
        actualWeight: Double? = nil, actualReps: Int? = nil, actualDuration: Int? = nil,
        status: String, setClass: String? = nil, completedAt: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.exerciseId = exerciseId
        self.sortOrder = sortOrder
        self.plannedWeight = plannedWeight
        self.plannedReps = plannedReps
        self.plannedDuration = plannedDuration
        self.actualWeight = actualWeight
        self.actualReps = actualReps
        self.actualDuration = actualDuration
        self.status = status
        self.setClass = setClass
        self.completedAt = completedAt
    }
}

public struct ExerciseInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    public var category: String?            // SC-exercises §3b enum; NULL = unclassified

    public init(id: String, name: String, category: String?) {
        self.id = id
        self.name = name
        self.category = category
    }
}

public struct PRRow: Equatable, Sendable {  // personal_record post-0008, live rows only
    public var id: String
    public var exerciseId: String
    public var sessionId: String
    public var kind: String
    public var value: Double
    public var achievedAt: String

    public init(id: String, exerciseId: String, sessionId: String, kind: String, value: Double, achievedAt: String) {
        self.id = id
        self.exerciseId = exerciseId
        self.sessionId = sessionId
        self.kind = kind
        self.value = value
        self.achievedAt = achievedAt
    }
}

// MARK: - Output shapes

public struct TrendPoint: Equatable, Sendable {
    public var day: String
    public var value: Double
    public var segment: Int                 // increments when gap to previous point > gapBreakDays (BR-002)

    public init(day: String, value: Double, segment: Int) {
        self.day = day
        self.value = value
        self.segment = segment
    }
}

public struct WeekTonnage: Equatable, Sendable {
    public var week: String                 // ISO week key "YYYY-Www"
    public var tonnage: Double

    public init(week: String, tonnage: Double) {
        self.week = week
        self.tonnage = tonnage
    }
}

public struct MuscleBucket: Equatable, Sendable {
    public var bucket: String               // upper|lower|other (BR-004)
    public var tonnage: Double
    public var pct: Double                  // unrounded; sums to 100 within float epsilon

    public init(bucket: String, tonnage: Double, pct: Double) {
        self.bucket = bucket
        self.tonnage = tonnage
        self.pct = pct
    }
}

public struct PRListItem: Equatable, Sendable {
    public var id: String
    public var exerciseId: String
    public var exerciseName: String
    public var kind: String
    public var sessionId: String
    public var achievedAt: String
    public var day: String
    public var value: Double

    public init(id: String, exerciseId: String, exerciseName: String, kind: String,
                sessionId: String, achievedAt: String, day: String, value: Double) {
        self.id = id
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.kind = kind
        self.sessionId = sessionId
        self.achievedAt = achievedAt
        self.day = day
        self.value = value
    }
}

public struct HistoryRow: Equatable, Sendable {
    public var sessionId: String
    public var name: String?
    public var day: String
    public var startedAt: String
    public var completedCount: Int
    public var tonnage: Double
    public var prCount: Int                 // > 0 ⇒ history.badge.pr renders (SC-prs §6)

    public init(sessionId: String, name: String?, day: String, startedAt: String,
                completedCount: Int, tonnage: Double, prCount: Int) {
        self.sessionId = sessionId
        self.name = name
        self.day = day
        self.startedAt = startedAt
        self.completedCount = completedCount
        self.tonnage = tonnage
        self.prCount = prCount
    }
}

public struct HistoryMonth: Equatable, Sendable {
    public var month: String                // "YYYY-MM"
    public var rows: [HistoryRow]

    public init(month: String, rows: [HistoryRow]) {
        self.month = month
        self.rows = rows
    }
}

public struct PlanActualRow: Equatable, Sendable {
    public var setId: String
    public var exerciseId: String
    public var sortOrder: Int
    public var status: String
    public var setClass: String?
    public var plannedWeight: Double?
    public var plannedReps: Int?
    public var plannedDuration: Int?
    public var actualWeight: Double?
    public var actualReps: Int?
    public var actualDuration: Int?

    public init(setId: String, exerciseId: String, sortOrder: Int, status: String, setClass: String?,
                plannedWeight: Double?, plannedReps: Int?, plannedDuration: Int?,
                actualWeight: Double?, actualReps: Int?, actualDuration: Int?) {
        self.setId = setId
        self.exerciseId = exerciseId
        self.sortOrder = sortOrder
        self.status = status
        self.setClass = setClass
        self.plannedWeight = plannedWeight
        self.plannedReps = plannedReps
        self.plannedDuration = plannedDuration
        self.actualWeight = actualWeight
        self.actualReps = actualReps
        self.actualDuration = actualDuration
    }
}

public struct AdherenceHeader: Equatable, Sendable {
    public var sessionsLast7: Int
    public var sessionsLast30: Int
    public var currentStreak: Int

    public init(sessionsLast7: Int, sessionsLast30: Int, currentStreak: Int) {
        self.sessionsLast7 = sessionsLast7
        self.sessionsLast30 = sessionsLast30
        self.currentStreak = currentStreak
    }
}

// MARK: - Engine

public enum AnalyticsEngine {

    // MARK: Closed-form UTC day/week math (mirrored byte-identically by VerifyAnalytics.mjs)

    /// UTC calendar day of an ISO-8601 UTC timestamp: the leading "YYYY-MM-DD".
    public static func utcDay(_ iso: String) -> String {
        String(iso.prefix(10))
    }

    /// Days since 1970-01-01 for a "YYYY-MM-DD" day (Howard Hinnant days_from_civil;
    /// proleptic Gregorian). Inputs in this codebase are always well-formed; a
    /// malformed day maps to 0 rather than trapping (read surface never crashes).
    public static func dayNumber(_ day: String) -> Int {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return daysFromCivil(year: parts[0], month: parts[1], day: parts[2])
    }

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var y = year
        if month <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                   // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// Inverse of `daysFromCivil` → (year, month, day) (civil_from_days).
    static func civil(fromDayNumber z: Int) -> (year: Int, month: Int, day: Int) {
        let zs = z + 719468
        let era = (zs >= 0 ? zs : zs - 146096) / 146097
        let doe = zs - era * 146097                               // [0, 146096]
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// "YYYY-MM-DD" for a day number.
    static func dayString(_ dayNumber: Int) -> String {
        let c = civil(fromDayNumber: dayNumber)
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    /// Monday-indexed weekday of a day number: Mon=0 … Sun=6. 1970-01-01 (day 0)
    /// was a Thursday.
    static func mondayIndex(_ dayNumber: Int) -> Int {
        let thu0 = ((dayNumber % 7) + 7) % 7                      // 0 = Thursday
        return (thu0 + 3) % 7
    }

    /// ISO-8601 week key "YYYY-Www": weeks start Monday; the week containing Jan 4
    /// is W01; the key's year is the year of the week's Thursday.
    public static func isoWeekKey(_ day: String) -> String {
        let dn = dayNumber(day)
        let thursday = dn + (3 - mondayIndex(dn))
        let isoYear = civil(fromDayNumber: thursday).year
        let jan4 = daysFromCivil(year: isoYear, month: 1, day: 4)
        let week1Thursday = jan4 + (3 - mondayIndex(jan4))
        let week = (thursday - week1Thursday) / 7 + 1
        return String(format: "%04d-W%02d", isoYear, week)
    }

    /// Epley estimated 1RM: weight × (1 + reps/30), unrounded (SC-prs §3b).
    public static func epley1RM(weight: Double, reps: Int) -> Double {
        weight * (1.0 + Double(reps) / 30.0)
    }

    /// INV-6: NULL setClass coalesces to work; only 'warmup' is excluded.
    static func isWorkClass(_ setClass: String?) -> Bool {
        (setClass ?? "work") == "work"
    }

    /// Day → session window filter (INV-A4): inclusive [today − (rangeDays − 1), today].
    static func sessionDays(inWindowAroundToday today: String, rangeDays: Int, sessions: [AnalyticsSession]) -> [String: String] {
        let hi = dayNumber(today)
        let lo = hi - (rangeDays - 1)
        var out: [String: String] = [:]
        for s in sessions {
            let day = utcDay(s.startedAt)
            let dn = dayNumber(day)
            if dn >= lo && dn <= hi { out[s.id] = day }
        }
        return out
    }

    // MARK: BR-001 — streak + adherence header

    /// Days carrying ≥1 live set with logged actuals that was not dropped:
    /// status ∈ {completed, failed} (SC-workout-logging BR-002; dropped/planned
    /// rows carry no actuals, INV-W2). Sorted ascending.
    public static func qualifyingDays(sessions: [AnalyticsSession], sets: [AnalyticsSet]) -> [String] {
        var dayBySession: [String: String] = [:]
        for s in sessions { dayBySession[s.id] = utcDay(s.startedAt) }
        var days = Set<String>()
        for set in sets where set.status == "completed" || set.status == "failed" {
            if let day = dayBySession[set.sessionId] { days.insert(day) }
        }
        return days.sorted()
    }

    /// Consecutive qualifying days ending at the anchor: today if it qualifies,
    /// else yesterday; 0 when neither qualifies (BR-001).
    public static func currentStreak(qualifyingDays: [String], today: String) -> Int {
        let days = Set(qualifyingDays)
        guard !days.isEmpty else { return 0 }
        var anchor = dayNumber(today)
        if !days.contains(dayString(anchor)) {
            anchor -= 1                                           // yesterday keeps a live streak alive
            guard days.contains(dayString(anchor)) else { return 0 }
        }
        var count = 0
        var cursor = anchor
        while days.contains(dayString(cursor)) {
            count += 1
            cursor -= 1
        }
        return count
    }

    /// BR-010 session counts + BR-001 streak in one header read.
    public static func adherenceHeader(sessions: [AnalyticsSession], sets: [AnalyticsSet], today: String) -> AdherenceHeader {
        let todayNum = dayNumber(today)
        func count(withinDays n: Int) -> Int {
            let lo = todayNum - (n - 1)
            return sessions.filter { s in
                let dn = dayNumber(utcDay(s.startedAt))
                return dn >= lo && dn <= todayNum
            }.count
        }
        return AdherenceHeader(
            sessionsLast7: count(withinDays: 7),
            sessionsLast30: count(withinDays: 30),
            currentStreak: currentStreak(qualifyingDays: qualifyingDays(sessions: sessions, sets: sets), today: today)
        )
    }

    // MARK: BR-002 — Epley 1RM trend

    /// One point per session/day with ≥1 qualifying set for the exercise
    /// (completed work sets with weight>0, reps>0); value = max Epley over the
    /// day's qualifying sets; gap > gapBreakDays days between consecutive points
    /// starts a new segment. Windowed by [today − (rangeDays − 1), today].
    public static func epleyTrend(
        sessions: [AnalyticsSession],
        sets: [AnalyticsSet],
        exerciseId: String,
        today: String,
        rangeDays: Int,
        gapBreakDays: Int = 7
    ) -> [TrendPoint] {
        let window = sessionDays(inWindowAroundToday: today, rangeDays: rangeDays, sessions: sessions)
        var bestByDay: [String: Double] = [:]
        for set in sets where set.exerciseId == exerciseId && set.status == "completed" && isWorkClass(set.setClass) {
            guard let day = window[set.sessionId] else { continue }
            guard let w = set.actualWeight, w > 0, let r = set.actualReps, r > 0 else { continue }
            let v = epley1RM(weight: w, reps: r)
            if let cur = bestByDay[day] {
                bestByDay[day] = max(cur, v)
            } else {
                bestByDay[day] = v
            }
        }
        var points: [TrendPoint] = []
        var segment = 0
        var prevDayNum: Int? = nil
        for day in bestByDay.keys.sorted() {
            let dn = dayNumber(day)
            if let prev = prevDayNum, dn - prev > gapBreakDays { segment += 1 }
            points.append(TrendPoint(day: day, value: bestByDay[day] ?? 0, segment: segment))
            prevDayNum = dn
        }
        return points
    }

    // MARK: BR-003 — weekly tonnage (warmups excluded)

    /// Σ actualWeight×actualReps per ISO week over completed non-warmup sets with
    /// both actuals present; weeks with zero volume are absent (INV-A3).
    public static func weeklyTonnage(
        sessions: [AnalyticsSession],
        sets: [AnalyticsSet],
        today: String,
        rangeDays: Int
    ) -> [WeekTonnage] {
        let window = sessionDays(inWindowAroundToday: today, rangeDays: rangeDays, sessions: sessions)
        var byWeek: [String: Double] = [:]
        for set in sets where set.status == "completed" && !((set.setClass ?? "work") == "warmup") {
            guard let day = window[set.sessionId] else { continue }
            guard let w = set.actualWeight, let r = set.actualReps else { continue }
            byWeek[isoWeekKey(day), default: 0] += w * Double(r)
        }
        return byWeek.keys.sorted().map { WeekTonnage(week: $0, tonnage: byWeek[$0] ?? 0) }
    }

    // MARK: BR-004 — muscle split

    public static let upperCategories: Set<String> = ["chest", "back", "shoulders", "biceps", "triceps", "forearms"]
    public static let lowerCategories: Set<String> = ["quads", "hamstrings", "glutes", "calves"]

    /// Bucket for an exercise category: upper/lower per the BR-004 maps;
    /// everything else (core, fullBody, cardio, other, NULL) → other.
    public static func bucket(forCategory category: String?) -> String {
        guard let c = category else { return "other" }
        if upperCategories.contains(c) { return "upper" }
        if lowerCategories.contains(c) { return "lower" }
        return "other"
    }

    /// Non-zero buckets in fixed order upper, lower, other with unrounded pct.
    public static func muscleSplit(
        sessions: [AnalyticsSession],
        sets: [AnalyticsSet],
        exercises: [ExerciseInfo],
        today: String,
        rangeDays: Int
    ) -> [MuscleBucket] {
        var categoryByID: [String: String?] = [:]
        for e in exercises { categoryByID[e.id] = e.category }
        let window = sessionDays(inWindowAroundToday: today, rangeDays: rangeDays, sessions: sessions)
        var byBucket: [String: Double] = [:]
        for set in sets where set.status == "completed" && isWorkClass(set.setClass) {
            guard let day = window[set.sessionId] else { continue }
            guard let w = set.actualWeight, let r = set.actualReps else { continue }
            let bucket = self.bucket(forCategory: categoryByID[set.exerciseId] ?? nil)
            byBucket[bucket, default: 0] += w * Double(r)
        }
        let total = byBucket.values.reduce(0, +)
        guard total > 0 else { return [] }
        return ["upper", "lower", "other"].compactMap { name in
            guard let t = byBucket[name], t > 0 else { return nil }
            return MuscleBucket(bucket: name, tonnage: t, pct: t / total * 100.0)
        }
    }

    // MARK: BR-005 — PR list

    /// Reverse-chronological live PRs; deterministic tie-break exerciseId, kind.
    /// Names resolve including tombstoned exercises (INV-L3).
    public static func prList(rows: [PRRow], exercises: [ExerciseInfo]) -> [PRListItem] {
        var nameByID: [String: String] = [:]
        for e in exercises { nameByID[e.id] = e.name }
        return rows
            .sorted { a, b in
                if a.achievedAt != b.achievedAt { return a.achievedAt > b.achievedAt }
                if a.exerciseId != b.exerciseId { return a.exerciseId < b.exerciseId }
                return a.kind < b.kind
            }
            .map { row in
                PRListItem(
                    id: row.id,
                    exerciseId: row.exerciseId,
                    exerciseName: nameByID[row.exerciseId] ?? "",
                    kind: row.kind,
                    sessionId: row.sessionId,
                    achievedAt: row.achievedAt,
                    day: utcDay(row.achievedAt),
                    value: row.value
                )
            }
    }

    // MARK: BR-006 — History

    /// Month-grouped sessions: months descending, rows startedAt-descending within
    /// a month (tie-break id). Row tonnage uses BR-003's gate; prCount is the live
    /// personal_record row count for the session (badge probe, SC-prs §3a).
    public static func history(
        sessions: [AnalyticsSession],
        sets: [AnalyticsSet],
        prs: [PRRow]
    ) -> [HistoryMonth] {
        var setsBySession: [String: [AnalyticsSet]] = [:]
        for set in sets { setsBySession[set.sessionId, default: []].append(set) }
        var prCountBySession: [String: Int] = [:]
        for pr in prs { prCountBySession[pr.sessionId, default: 0] += 1 }

        var rowsByMonth: [String: [HistoryRow]] = [:]
        for session in sessions {
            let day = utcDay(session.startedAt)
            let month = String(day.prefix(7))
            let sessionSets = setsBySession[session.id] ?? []
            var tonnage = 0.0
            var completedCount = 0
            for set in sessionSets where set.status == "completed" {
                completedCount += 1
                if isWorkClass(set.setClass), let w = set.actualWeight, let r = set.actualReps {
                    tonnage += w * Double(r)
                }
            }
            rowsByMonth[month, default: []].append(HistoryRow(
                sessionId: session.id,
                name: session.name,
                day: day,
                startedAt: session.startedAt,
                completedCount: completedCount,
                tonnage: tonnage,
                prCount: prCountBySession[session.id] ?? 0
            ))
        }
        return rowsByMonth.keys.sorted(by: >).map { month in
            let rows = (rowsByMonth[month] ?? []).sorted { a, b in
                if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
                return a.sessionId < b.sessionId
            }
            return HistoryMonth(month: month, rows: rows)
        }
    }

    // MARK: BR-007 — session detail (plan-vs-actual)

    /// The session's sets in sortOrder with the dual planned/actual columns intact
    /// (INV-5). Failed rows keep their recorded actuals (SC-workout-logging BR-002).
    public static func sessionDetailRows(sessionId: String, sets: [AnalyticsSet]) -> [PlanActualRow] {
        sets
            .filter { $0.sessionId == sessionId }
            .sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.id < b.id
            }
            .map { s in
                PlanActualRow(
                    setId: s.id,
                    exerciseId: s.exerciseId,
                    sortOrder: s.sortOrder,
                    status: s.status,
                    setClass: s.setClass,
                    plannedWeight: s.plannedWeight,
                    plannedReps: s.plannedReps,
                    plannedDuration: s.plannedDuration,
                    actualWeight: s.actualWeight,
                    actualReps: s.actualReps,
                    actualDuration: s.actualDuration
                )
            }
    }
}
