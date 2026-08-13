// Ticket #37 — History surface state. Foundation-only (@Observable, no SwiftUI)
// so it parses/verifies off-Mac; the SwiftUI layer in Views/ binds to this
// surface and stays thin.
//
// Architecture: this model DRIVES the frozen SC-analytics@1.0.0 seams — it
// never reimplements them:
//   • AnalyticsEngine / AnalyticsDAO (read-only): month-grouped history
//     (BR-006), session detail dual-column rows (BR-007 / INV-5), and the
//     per-exercise Epley sparkline = BR-002 points over full history with
//     segment info intact (gap > 7 days breaks the line, never zero-filled —
//     BR-002 / INV-A3).
//   • PersonalRecordDAO.fetchSessionPRBadges (#36 groundwork, SC-prs §3a):
//     the per-session live PR counts that render `history.badge.pr`. The probe
//     rides `personal_record_session_idx` — a tombstoned session or PR row
//     never badges (INV-A2).
//
// All aggregation stays in the engine; this model only shapes render-ready
// display values (copy + unit-aware formatting per SC-settings BR-001).

import Foundation
import Observation
import MooreAnalytics
import MooreRecords
import MooreSettings

// MARK: - Display value types (render-ready; views never format)

/// One month section of the History list (BR-006: months descend, rows
/// startedAt-descending within a month).
public struct HistoryMonthSection: Identifiable, Equatable, Sendable {
    public var id: String { monthKey }
    /// "YYYY-MM" — UTC month of `startedAt`.
    public let monthKey: String
    /// Resolved `history.monthHeader` ("{monthName} {year}").
    public let monthTitle: String
    public let rows: [HistorySessionRow]

    public init(monthKey: String, monthTitle: String, rows: [HistorySessionRow]) {
        self.monthKey = monthKey
        self.monthTitle = monthTitle
        self.rows = rows
    }
}

/// One session row in the History list.
public struct HistorySessionRow: Identifiable, Equatable, Sendable {
    public var id: String { sessionId }
    public let sessionId: String
    /// Display name — session `name`, NULL-tolerant (falls back to
    /// `workout.adhoc_title`).
    public let title: String
    /// The session's UTC day, display-formatted.
    public let dateText: String
    /// `history.session.sets` ("{n} sets") — completedCount, any class (BR-006).
    public let setsText: String
    /// Work-set tonnage (BR-003's gate), unit-aware; nil when zero.
    public let tonnageText: String?
    /// Live personal_record rows for the session (badge probe).
    public let prCount: Int
    /// > 0 ⇒ `history.badge.pr` renders (SC-prs §6).
    public var showsPrBadge: Bool { prCount > 0 }

    public init(sessionId: String, title: String, dateText: String, setsText: String, tonnageText: String?, prCount: Int) {
        self.sessionId = sessionId
        self.title = title
        self.dateText = dateText
        self.setsText = setsText
        self.tonnageText = tonnageText
        self.prCount = prCount
    }
}

/// One point of a per-exercise e1RM sparkline — a BR-002 TrendPoint shaped for
/// plotting: UTC date, display-unit value, segment intact.
public struct SparklinePoint: Identifiable, Equatable, Sendable {
    public var id: String { day }
    public let day: String
    public let date: Date
    /// Display-unit e1RM (chart plots in the active unit).
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

/// One set row of the session detail plan-vs-actual table (BR-007 / INV-5:
/// dual columns side-by-side; failed rows keep their recorded actuals).
public struct SessionDetailSetRow: Identifiable, Equatable, Sendable {
    public var id: String { setId }
    public let setId: String
    /// planned|completed|failed|dropped
    public let status: String
    public let setClass: String?
    public var isWarmup: Bool { setClass == "warmup" }
    /// Planned-column cell ("{weight} × {reps}" / "{duration}s" / "—").
    public let plannedText: String
    /// Actual-column cell.
    public let actualText: String

    public init(setId: String, status: String, setClass: String?, plannedText: String, actualText: String) {
        self.setId = setId
        self.status = status
        self.setClass = setClass
        self.plannedText = plannedText
        self.actualText = actualText
    }
}

/// One exercise group inside the session detail: name + full-history e1RM
/// sparkline (BR-007) above its plan-vs-actual rows.
public struct SessionDetailExerciseGroup: Identifiable, Equatable, Sendable {
    public var id: String { exerciseId }
    public let exerciseId: String
    /// Resolved including tombstones (INV-L3 / INV-A2 names exception).
    public let exerciseName: String
    public let sparkline: [SparklinePoint]
    public let rows: [SessionDetailSetRow]

    public init(exerciseId: String, exerciseName: String, sparkline: [SparklinePoint], rows: [SessionDetailSetRow]) {
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.sparkline = sparkline
        self.rows = rows
    }
}

/// The full session detail surface (BR-007).
public struct SessionDetailDisplay: Equatable, Sendable {
    public let sessionId: String
    public let title: String
    public let dateText: String
    public let groups: [SessionDetailExerciseGroup]

    public init(sessionId: String, title: String, dateText: String, groups: [SessionDetailExerciseGroup]) {
        self.sessionId = sessionId
        self.title = title
        self.dateText = dateText
        self.groups = groups
    }
}

// MARK: - HistoryModel

@Observable
public final class HistoryModel {

    // MARK: Observable surface (the views render ONLY this)

    /// Month-grouped history; empty ⇔ zero-data state (BR-008: rendered, never
    /// gated — the view shows the empty container, never an unlock threshold).
    public private(set) var months: [HistoryMonthSection] = []
    /// The loaded session detail; `detailSessionId` guards stale renders.
    public private(set) var detail: SessionDetailDisplay?
    public private(set) var detailSessionId: String?

    // MARK: Engines & seams (driven, never reimplemented)

    private let analyticsDAO: AnalyticsDAO
    private let prDAO: PersonalRecordDAO
    private let settingsDAO: SettingsDAO

    public init(analyticsDAO: AnalyticsDAO, prDAO: PersonalRecordDAO, settingsDAO: SettingsDAO) {
        self.analyticsDAO = analyticsDAO
        self.prDAO = prDAO
        self.settingsDAO = settingsDAO
    }

    // MARK: List surface (BR-006)

    /// Cold re-read from SQLite: month-grouped sessions with PR badge counts.
    /// The grouping/tonnage/completed math is `AnalyticsEngine.history`; the
    /// badge counts ride #36's `fetchSessionPRBadges` probe (SC-prs §3a
    /// `personal_record_session_idx`) rather than a full PR scan. A storage
    /// hiccup degrades to the empty state, never a crash.
    public func refresh() {
        do {
            let sessions = try analyticsDAO.fetchSessions()
            let sets = try analyticsDAO.fetchSets()
            let badges = (try? prDAO.fetchSessionPRBadges()) ?? []
            var prCountBySession: [String: Int] = [:]
            for badge in badges { prCountBySession[badge.sessionId] = badge.prCount }

            let unit = currentUnit
            let engineMonths = AnalyticsEngine.history(sessions: sessions, sets: sets, prs: [])
            months = engineMonths.map { month in
                HistoryMonthSection(
                    monthKey: month.month,
                    monthTitle: Self.monthTitle(for: month.month),
                    rows: month.rows.map { row in
                        HistorySessionRow(
                            sessionId: row.sessionId,
                            title: row.name ?? UICopy.workoutAdhocTitle,
                            dateText: Self.dateText(forDay: row.day),
                            setsText: UICopy.historySessionSets(row.completedCount),
                            tonnageText: row.tonnage > 0 ? Self.tonnageText(row.tonnage, unit: unit) : nil,
                            prCount: prCountBySession[row.sessionId] ?? 0
                        )
                    }
                )
            }
        } catch {
            months = []
        }
    }

    // MARK: Detail surface (BR-007)

    /// Load the session's plan-vs-actual rows + per-exercise e1RM sparklines.
    /// Always re-reads (cold-render rule — the read is cheap and a live session
    /// can gain sets between appearances).
    /// Rows are `AnalyticsEngine.sessionDetailRows` (sortOrder ASC, dual
    /// columns intact, failed actuals kept); each sparkline is
    /// `AnalyticsEngine.epleyTrend` over full history (the DAO's unwindowed
    /// 36500-day window) so segments break across >7-day gaps exactly as the
    /// trend does.
    public func loadDetail(sessionId: String) {
        do {
            let sessions = try analyticsDAO.fetchSessions()
            let sets = try analyticsDAO.fetchSets()
            let exercises = try analyticsDAO.fetchExercises()
            var nameByID: [String: String] = [:]
            for e in exercises { nameByID[e.id] = e.name }

            let session = sessions.first { $0.id == sessionId }
            let rows = AnalyticsEngine.sessionDetailRows(sessionId: sessionId, sets: sets)
            let today = Self.utcToday()
            let unit = currentUnit

            // Group by exercise preserving first-appearance sortOrder order.
            var groupOrder: [String] = []
            var rowsByExercise: [String: [PlanActualRow]] = [:]
            for row in rows {
                if rowsByExercise[row.exerciseId] == nil { groupOrder.append(row.exerciseId) }
                rowsByExercise[row.exerciseId, default: []].append(row)
            }

            let groups = groupOrder.map { exerciseId -> SessionDetailExerciseGroup in
                let exerciseRows = rowsByExercise[exerciseId] ?? []
                let points = AnalyticsEngine.epleyTrend(
                    sessions: sessions, sets: sets, exerciseId: exerciseId,
                    today: today, rangeDays: 36500
                )
                return SessionDetailExerciseGroup(
                    exerciseId: exerciseId,
                    exerciseName: nameByID[exerciseId] ?? exerciseId,
                    sparkline: points.compactMap { p in
                        guard let date = Self.date(fromDay: p.day) else { return nil }
                        return SparklinePoint(
                            day: p.day,
                            date: date,
                            value: SettingsEngine.displayValue(rawKg: p.value, unit: unit),
                            valueText: SettingsEngine.displayString(rawKg: p.value, unit: unit),
                            segment: p.segment
                        )
                    },
                    rows: exerciseRows.map { r in
                        SessionDetailSetRow(
                            setId: r.setId,
                            status: r.status,
                            setClass: r.setClass,
                            plannedText: Self.cellText(weight: r.plannedWeight, reps: r.plannedReps, duration: r.plannedDuration, unit: unit),
                            actualText: Self.cellText(weight: r.actualWeight, reps: r.actualReps, duration: r.actualDuration, unit: unit)
                        )
                    }
                )
            }

            detail = SessionDetailDisplay(
                sessionId: sessionId,
                title: session?.name ?? UICopy.workoutAdhocTitle,
                dateText: session.map { Self.dateText(forDay: AnalyticsEngine.utcDay($0.startedAt)) } ?? "",
                groups: groups
            )
            detailSessionId = sessionId
        } catch {
            // Storage hiccup → honest empty container, never a crash (BR-008).
            detail = SessionDetailDisplay(sessionId: sessionId, title: UICopy.workoutAdhocTitle, dateText: "", groups: [])
            detailSessionId = sessionId
        }
    }

    // MARK: Internals

    /// SC-settings BR-001: the display unit is read at render time; storage
    /// stays canonical kg (INV-ST2).
    private var currentUnit: WeightUnit {
        (try? settingsDAO.fetchSettings().weightUnit) ?? .kg
    }

    /// One plan/actual table cell: "{weight} × {reps}" (weight unit-aware),
    /// duration as "{n}s", bare reps for bodyweight rows, "—" when empty.
    static func cellText(weight: Double?, reps: Int?, duration: Int?, unit: WeightUnit) -> String {
        if let w = weight, let r = reps {
            return "\(SettingsEngine.displayString(rawKg: w, unit: unit)) × \(r)"
        }
        if let w = weight {
            return SettingsEngine.displayString(rawKg: w, unit: unit)
        }
        if let d = duration {
            return "\(d)s"
        }
        if let r = reps {
            return "\(r)"
        }
        return "—"
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

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let utc: TimeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.timeZone = utc
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.timeZone = utc
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static let monthNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.timeZone = utc
        f.dateFormat = "MMMM"
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.timeZone = utc
        f.dateFormat = "yyyy"
        return f
    }()

    private static let rowDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.timeZone = utc
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    static func date(fromDay day: String) -> Date? {
        dayParser.date(from: day)
    }

    /// "YYYY-MM" → `history.monthHeader` ("August 2026"); malformed keys
    /// render verbatim (read surface never crashes).
    static func monthTitle(for monthKey: String) -> String {
        guard let parsed = monthParser.date(from: monthKey) else { return monthKey }
        return UICopy.historyMonthHeader(
            monthName: monthNameFormatter.string(from: parsed),
            year: yearFormatter.string(from: parsed)
        )
    }

    static func dateText(forDay day: String) -> String {
        guard let parsed = dayParser.date(from: day) else { return day }
        return rowDateFormatter.string(from: parsed)
    }
}
