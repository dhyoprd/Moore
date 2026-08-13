// Ticket #37 — Analytics surface state. Foundation-only (@Observable, no
// SwiftUI) so it parses/verifies off-Mac; the SwiftUI layer in Views/ binds to
// this surface and stays thin.
//
// Architecture: STRICTLY DERIVED (SC-analytics@1.0.0 INV-A1 — analytics never
// persisted; #3 invariant 5). This model DRIVES the frozen seams — it never
// reimplements them:
//   • AnalyticsDAO.adherenceHeader  — streak + 7/30-day session counts
//     (BR-001/BR-010; day-based streak, yesterday-anchor, week boundaries
//     invisible).
//   • AnalyticsEngine.epleyTrend    — per-exercise Epley 1RM trend; a gap
//     > 7 days between points breaks the line into a new segment — no
//     zero-fill, no phantom flat lines (BR-002 / INV-A3).
//   • AnalyticsDAO.weeklyTonnage    — ISO-week tonnage, warmups excluded
//     (BR-003); zero-volume weeks absent.
//   • AnalyticsDAO.muscleSplit      — upper/lower/other buckets, pct sums to
//     100 within float epsilon (BR-004; AC bound ±0.1%).
//   • AnalyticsDAO.prList           — reverse-chronological live PRs with
//     tombstone-tolerant exercise names (BR-005 / INV-L3).
//
// BR-008: empty is RENDERED, never gated — every section always ships its
// container; zero data shows the §6 empty copy, no unlock threshold.
// BR-009: the window is the default 30-day "last 30 days or less"; History +
// PR list are unwindowed (full log).

import Foundation
import Observation
import MooreAnalytics
import MooreSettings

// MARK: - Display value types (render-ready; views never format)

/// One selectable exercise for the 1RM trend chart.
public struct TrendExerciseOption: Identifiable, Equatable, Sendable {
    public let id: String             // exerciseId
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One plotted point of the Epley 1RM trend (BR-002): UTC date, display-unit
/// value, segment intact (segment increments across >7-day gaps — the chart
/// breaks the line there).
public struct TrendPointDisplay: Identifiable, Equatable, Sendable {
    public var id: String { "\(day)-\(segment)" }
    public let day: String
    public let date: Date
    public let value: Double
    public let valueText: String
    public let segment: Int

    public init(day: String, date: Date, value: Double, valueText: String, segment: Int) {
        self.day = day
        self.date = date
        self.value = value
        self.valueText = valueText
        self.segment = segment
    }
}

/// One weekly tonnage bar (BR-003): ISO week key + unit-aware tonnage.
public struct TonnageBarDisplay: Identifiable, Equatable, Sendable {
    public var id: String { week }
    /// "YYYY-Www" ISO week key (plotted as a category axis, ascending).
    public let week: String
    public let tonnage: Double
    public let tonnageText: String

    public init(week: String, tonnage: Double, tonnageText: String) {
        self.week = week
        self.tonnage = tonnage
        self.tonnageText = tonnageText
    }
}

/// One muscle-split bucket row (BR-004): fixed upper/lower/other order,
/// unrounded pct (sums to 100 within float epsilon).
public struct MuscleSplitRow: Identifiable, Equatable, Sendable {
    public var id: String { bucket }
    public let bucket: String
    /// analytics.split.bucket.* label.
    public let label: String
    /// 0...100, unrounded.
    public let pct: Double
    /// "43.1%" display shape.
    public let pctText: String
    public let tonnageText: String

    public init(bucket: String, label: String, pct: Double, pctText: String, tonnageText: String) {
        self.bucket = bucket
        self.label = label
        self.pct = pct
        self.pctText = pctText
        self.tonnageText = tonnageText
    }
}

/// One reverse-chronological PR list row (BR-005).
public struct PRListRowDisplay: Identifiable, Equatable, Sendable {
    public let id: String
    public let exerciseId: String
    public let exerciseName: String
    public let kindRaw: String
    /// pr.kind.* §6 label.
    public let kindLabel: String
    public let valueText: String
    public let dayText: String
    /// Deep-link handle per #27 (carried, not navigated yet).
    public let sessionId: String

    public init(id: String, exerciseId: String, exerciseName: String, kindRaw: String, kindLabel: String, valueText: String, dayText: String, sessionId: String) {
        self.id = id
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.kindRaw = kindRaw
        self.kindLabel = kindLabel
        self.valueText = valueText
        self.dayText = dayText
        self.sessionId = sessionId
    }
}

// MARK: - AnalyticsModel

@Observable
public final class AnalyticsModel {

    /// BR-009: "last 30 days or less" — the default window for every windowed
    /// query (trend, tonnage, split, header counts).
    public static let defaultRangeDays = 30

    // MARK: Observable surface (the views render ONLY this)

    // Header (BR-001 / BR-010).
    public private(set) var sessionsLast7 = 0
    public private(set) var sessionsLast30 = 0
    public private(set) var streakDays = 0

    // Trend (BR-002).
    public private(set) var trendOptions: [TrendExerciseOption] = []
    public private(set) var selectedTrendExerciseId: String?
    public private(set) var trendPoints: [TrendPointDisplay] = []

    // Tonnage (BR-003) / split (BR-004) / PR list (BR-005).
    public private(set) var tonnageBars: [TonnageBarDisplay] = []
    public private(set) var splitRows: [MuscleSplitRow] = []
    public private(set) var prRows: [PRListRowDisplay] = []

    /// Zero-data honesty (BR-008): streak 0 reads "No streak yet", never
    /// hidden; sections with no qualifying data render their §6 empty copy.
    public var streakValueText: String {
        streakDays > 0 ? UICopy.analyticsStreakDays(streakDays) : UICopy.analyticsStreakNone
    }
    public var last7Text: String { UICopy.analyticsHeaderLast7(sessionsLast7) }
    public var last30Text: String { UICopy.analyticsHeaderLast30(sessionsLast30) }

    // MARK: Engines & seams (driven, never reimplemented)

    private let analyticsDAO: AnalyticsDAO
    private let settingsDAO: SettingsDAO

    /// Cached raw reads so switching the trend exercise re-derives without a
    /// fresh DB round-trip (still derived, never stored aggregates — INV-A1).
    private var cachedSessions: [AnalyticsSession] = []
    private var cachedSets: [AnalyticsSet] = []
    private var cachedToday = ""

    public init(analyticsDAO: AnalyticsDAO, settingsDAO: SettingsDAO) {
        self.analyticsDAO = analyticsDAO
        self.settingsDAO = settingsDAO
    }

    // MARK: Refresh (cold re-read; every number recomputes at read time)

    public func refresh() {
        let today = Self.utcToday()
        let unit = currentUnit
        do {
            // One raw read pass (INV-A2 tombstone discipline lives in the DAO
            // fetchers); every aggregate below is a pure AnalyticsEngine call
            // over these inputs — strictly derived, never stored (INV-A1).
            let sessions = try analyticsDAO.fetchSessions()
            let sets = try analyticsDAO.fetchSets()
            let exercises = try analyticsDAO.fetchExercises()
            let prRowsRaw = try analyticsDAO.fetchPRRows()
            cachedSessions = sessions
            cachedSets = sets
            cachedToday = today

            // Header: streak + session counts (BR-001/BR-010).
            let header = AnalyticsEngine.adherenceHeader(sessions: sessions, sets: sets, today: today)
            sessionsLast7 = header.sessionsLast7
            sessionsLast30 = header.sessionsLast30
            streakDays = header.currentStreak

            // Weekly tonnage, warmups excluded (BR-003).
            tonnageBars = AnalyticsEngine.weeklyTonnage(sessions: sessions, sets: sets, today: today, rangeDays: Self.defaultRangeDays).map { w in
                TonnageBarDisplay(
                    week: w.week,
                    tonnage: SettingsEngine.displayValue(rawKg: w.tonnage, unit: unit),
                    tonnageText: Self.tonnageText(w.tonnage, unit: unit)
                )
            }

            // Muscle split (BR-004) — engine pct sums to 100 within epsilon.
            splitRows = AnalyticsEngine.muscleSplit(sessions: sessions, sets: sets, exercises: exercises, today: today, rangeDays: Self.defaultRangeDays).map { b in
                MuscleSplitRow(
                    bucket: b.bucket,
                    label: Self.bucketLabel(b.bucket),
                    pct: b.pct,
                    pctText: String(format: "%.1f%%", b.pct),
                    tonnageText: Self.tonnageText(b.tonnage, unit: unit)
                )
            }

            // PR list, reverse-chronological (BR-005) — unwindowed full log.
            prRows = AnalyticsEngine.prList(rows: prRowsRaw, exercises: exercises).map { item in
                PRListRowDisplay(
                    id: item.id,
                    exerciseId: item.exerciseId,
                    exerciseName: item.exerciseName,
                    kindRaw: item.kind,
                    kindLabel: UICopy.prKindLabel(item.kind),
                    valueText: Self.prValueText(kindRaw: item.kind, value: item.value, unit: unit),
                    dayText: Self.dateText(forDay: item.day),
                    sessionId: item.sessionId
                )
            }

            // Trend candidates + points (BR-002).
            rebuildTrendOptions(sessions: sessions, sets: sets, exercises: exercises)
            rebuildTrendPoints(unit: unit)
        } catch {
            // Storage hiccup → honest empty state, never a crash (BR-008).
            sessionsLast7 = 0
            sessionsLast30 = 0
            streakDays = 0
            tonnageBars = []
            splitRows = []
            prRows = []
            trendOptions = []
            trendPoints = []
            selectedTrendExerciseId = nil
            cachedSessions = []
            cachedSets = []
            cachedToday = today
        }
    }

    /// Exercise switch: re-derive the trend for the new selection from the
    /// cached raw reads (INV-A1 — still computed, never cached aggregates).
    public func selectTrendExercise(_ exerciseId: String?) {
        guard let exerciseId, trendOptions.contains(where: { $0.id == exerciseId }) else { return }
        guard exerciseId != selectedTrendExerciseId else { return }
        selectedTrendExerciseId = exerciseId
        rebuildTrendPoints(unit: currentUnit)
    }

    // MARK: Internals

    /// Candidates = exercises with ≥1 BR-002-qualifying set in full history
    /// (completed work set, weight>0, reps>0), ordered by first qualifying
    /// day then name. Names resolve including tombstones (INV-L3). This is a
    /// listing filter only — every plotted value comes from
    /// `AnalyticsEngine.epleyTrend`.
    private func rebuildTrendOptions(sessions: [AnalyticsSession], sets: [AnalyticsSet], exercises: [ExerciseInfo]) {
        var sessionDay: [String: String] = [:]
        for s in sessions { sessionDay[s.id] = AnalyticsEngine.utcDay(s.startedAt) }

        var firstDayByExercise: [String: String] = [:]
        for set in sets where set.status == "completed" && (set.setClass ?? "work") == "work" {
            guard let w = set.actualWeight, w > 0, let r = set.actualReps, r > 0 else { continue }
            guard let day = sessionDay[set.sessionId] else { continue }
            if let known = firstDayByExercise[set.exerciseId] {
                firstDayByExercise[set.exerciseId] = day < known ? day : known
            } else {
                firstDayByExercise[set.exerciseId] = day
            }
        }

        var nameByID: [String: String] = [:]
        for e in exercises { nameByID[e.id] = e.name }

        trendOptions = firstDayByExercise
            .sorted { a, b in
                if a.value != b.value { return a.value < b.value }
                return (nameByID[a.key] ?? a.key) < (nameByID[b.key] ?? b.key)
            }
            .map { TrendExerciseOption(id: $0.key, name: nameByID[$0.key] ?? $0.key) }

        if let current = selectedTrendExerciseId, trendOptions.contains(where: { $0.id == current }) {
            return   // keep the user's selection across refreshes
        }
        selectedTrendExerciseId = trendOptions.first?.id
    }

    /// The selected exercise's Epley trend inside the default window — engine
    /// math end-to-end (gap > 7 days ⇒ segment break, no zero-fill).
    private func rebuildTrendPoints(unit: WeightUnit) {
        guard let exerciseId = selectedTrendExerciseId else {
            trendPoints = []
            return
        }
        let points = AnalyticsEngine.epleyTrend(
            sessions: cachedSessions, sets: cachedSets, exerciseId: exerciseId,
            today: cachedToday, rangeDays: Self.defaultRangeDays
        )
        trendPoints = points.compactMap { p in
            guard let date = Self.date(fromDay: p.day) else { return nil }
            return TrendPointDisplay(
                day: p.day,
                date: date,
                value: SettingsEngine.displayValue(rawKg: p.value, unit: unit),
                valueText: SettingsEngine.displayString(rawKg: p.value, unit: unit),
                segment: p.segment
            )
        }
    }

    /// SC-settings BR-001: the display unit is read at render time; storage
    /// stays canonical kg (INV-ST2).
    private var currentUnit: WeightUnit {
        (try? settingsDAO.fetchSettings().weightUnit) ?? .kg
    }

    static func bucketLabel(_ bucket: String) -> String {
        switch bucket {
        case "upper": return UICopy.analyticsSplitBucketUpper
        case "lower": return UICopy.analyticsSplitBucketLower
        default: return UICopy.analyticsSplitBucketOther
        }
    }

    /// {value} render per kind (SC-prs §3b): weight-dimensioned kinds ride the
    /// display unit; reps and duration are unit-free. Unknown kinds render the
    /// raw value (forward-compat, never a crash — mirrors RecordsModel).
    static func prValueText(kindRaw: String, value: Double, unit: WeightUnit) -> String {
        switch kindRaw {
        case "max_1rm", "max_volume":
            return SettingsEngine.displayString(rawKg: value, unit: unit)
        case "max_reps":
            return "\(Int(value))"
        case "max_duration":
            return "\(Int(value))s"
        default:
            return "\(value)"
        }
    }

    static func tonnageText(_ tonnage: Double, unit: WeightUnit) -> String {
        String(format: "%.0f %@", SettingsEngine.displayValue(rawKg: tonnage, unit: unit), unit.rawValue)
    }

    /// UTC day string of "now" — analytics calendar math is UTC-day based
    /// (SC-analytics §3b), never the local timezone.
    static func utcToday() -> String {
        String(ISO8601DateFormatter().string(from: Date()).prefix(10))
    }

    // MARK: UTC display formatting (en_US_POSIX — deterministic)

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let rowDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    static func date(fromDay day: String) -> Date? {
        dayParser.date(from: day)
    }

    static func dateText(forDay day: String) -> String {
        guard let parsed = dayParser.date(from: day) else { return day }
        return rowDateFormatter.string(from: parsed)
    }
}
