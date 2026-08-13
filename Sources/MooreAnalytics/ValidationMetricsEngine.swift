// Ticket #43 — Self-validation metrics engine (the 8-week gate).
// Seam-1: pure, closed-form, Foundation only — no I/O, no state, no GRDB, no
// SwiftUI. Mirrors the AnalyticsEngine conventions exactly (SC-analytics §3b):
// all calendar math is UTC-day based — an ISO-8601 UTC timestamp's calendar day
// is its leading "YYYY-MM-DD"; week keys are ISO-8601 "YYYY-Www" via the same
// closed-form days_from_civil algorithm (reused from AnalyticsEngine, so the JS
// verifier mirrors both byte-identically).
//
// What this module stores vs derives (INV-A1 discipline, extended):
//   • DERIVED here, never persisted: weekly session counts, the ≥2-sessions week
//     streak, the logging-speed proxies, retention day counts, the gate verdict.
//   • STORED by 0012_validation_metrics.sql as raw inputs: app_open_event rows
//     (one per foreground — an event timeline like completed_set, source data)
//     and validation_baseline rows (builder-entered Hevy reference values).
//     Neither is a derived aggregate, so SC-analytics INV-A1 ("no derived field
//     stored") is intact — everything above recomputes from the rows at read.
//
// The gate itself is #4's activation trigger (§4 "Activation trigger"):
//   1. STREAK — ≥2 CompletedSet-bearing sessions per calendar week for
//      8 consecutive weeks (derived from local data; "the app is the
//      measurement").
//   2. DISPLACEMENT — during weeks 5–8, zero workout sessions logged in Hevy.
//      Human-judged: a manual confirmation, not derivable on-device.
//   3. RETENTION — app remains installed and the builder answers "would you
//      return to Hevy for next week?" with NO at the week-8 checkpoint.
//      Half derivable (installed+opened ≈ app_open_event cadence); the answer
//      itself is the second manual confirmation.

import Foundation

// MARK: - Read-model value types

/// One app foreground event (a row of app_open_event, 0012).
public struct ValidationOpenEvent: Equatable, Sendable {
    public var id: String
    public var openedAt: String             // ISO-8601 UTC

    public init(id: String, openedAt: String) {
        self.id = id
        self.openedAt = openedAt
    }
}

/// One validation_baseline row (0012): a dated, unit-carrying reference
/// measurement (e.g. the builder's Hevy logging speed), never a preference.
public struct ValidationBaseline: Equatable, Sendable {
    public var id: String
    public var metricKey: String
    public var value: Double
    public var unit: String
    public var recordedAt: String
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?

    public init(id: String, metricKey: String, value: Double, unit: String,
                recordedAt: String, createdAt: String, updatedAt: String, deletedAt: String? = nil) {
        self.id = id
        self.metricKey = metricKey
        self.value = value
        self.unit = unit
        self.recordedAt = recordedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

// MARK: - Output shapes

/// One ISO week's qualifying-session count (weeks with zero qualifying sessions
/// are ABSENT — the honest time axis, INV-A3).
public struct WeekSessionCount: Equatable, Sendable {
    public var week: String                 // ISO week key "YYYY-Www"
    public var sessionCount: Int

    public init(week: String, sessionCount: Int) {
        self.week = week
        self.sessionCount = sessionCount
    }
}

/// One ISO week's retention: distinct UTC days carrying ≥1 app-open event
/// (two opens the same day count once). Zero-event weeks are absent (INV-A3).
public struct WeekRetention: Equatable, Sendable {
    public var week: String
    public var distinctOpenDays: Int

    public init(week: String, distinctOpenDays: Int) {
        self.week = week
        self.distinctOpenDays = distinctOpenDays
    }
}

/// Logging-speed proxies (#43: "time/set … vs. a Hevy baseline"):
///   • medianSecondsPerSet — pooled median of within-session completedAt deltas
///     (consecutive completed sets, first set excluded — the time BEFORE the
///     first log is app-open friction, not logging speed).
///   • medianSessionSecondsPerSet — median over sessions of
///     (endedAt − startedAt) ÷ completed-set count (whole-session pace).
/// nil = not enough data yet (a single-set session yields no delta).
public struct SpeedProxy: Equatable, Sendable {
    public var medianSecondsPerSet: Double?
    public var medianSessionSecondsPerSet: Double?

    public init(medianSecondsPerSet: Double?, medianSessionSecondsPerSet: Double?) {
        self.medianSecondsPerSet = medianSecondsPerSet
        self.medianSessionSecondsPerSet = medianSessionSecondsPerSet
    }
}

/// The 8-week gate verdict states (#4 activation trigger).
public enum GateStatus: String, Equatable, Sendable {
    /// No week with ≥2 qualifying sessions has ever occurred.
    case notStarted = "NOT-STARTED"
    /// Streak underway (or the streak condition met but a manual confirmation
    /// still open).
    case inProgress = "IN-PROGRESS"
    /// ≥8 consecutive ≥2-session weeks AND both manual confirmations made.
    case pass = "PASS"
}

/// Full gate evaluation: the derived streak condition + the two human-judged
/// conditions (#4 §4 trigger lines 2–3) that only the builder can confirm.
public struct GateEvaluation: Equatable, Sendable {
    public var status: GateStatus
    /// Consecutive ≥2-session ISO weeks ending at the present anchor (BR-V2).
    public var weekStreak: Int
    public var streakConditionMet: Bool
    public var displacementConfirmed: Bool
    public var retentionConfirmed: Bool
    public var weeksRequired: Int
    public var sessionsPerWeekRequired: Int

    public init(status: GateStatus, weekStreak: Int, streakConditionMet: Bool,
                displacementConfirmed: Bool, retentionConfirmed: Bool,
                weeksRequired: Int, sessionsPerWeekRequired: Int) {
        self.status = status
        self.weekStreak = weekStreak
        self.streakConditionMet = streakConditionMet
        self.displacementConfirmed = displacementConfirmed
        self.retentionConfirmed = retentionConfirmed
        self.weeksRequired = weeksRequired
        self.sessionsPerWeekRequired = sessionsPerWeekRequired
    }
}

// MARK: - Engine

public enum ValidationMetricsEngine {

    /// #4 trigger: 8 consecutive weeks…
    public static let gateWeeksRequired = 8
    /// …each carrying ≥2 CompletedSet-bearing sessions.
    public static let gateSessionsPerWeek = 2

    // MARK: Timestamp math (closed-form, mirrored byte-identically by VerifyValidation.mjs)

    /// Epoch seconds of an ISO-8601 UTC timestamp ("YYYY-MM-DDTHH:MM:SS(.f)?Z?"),
    /// computed closed-form from AnalyticsEngine's days_from_civil — no
    /// DateFormatter (deterministic across platforms; nil on malformed input).
    public static func epochSeconds(_ iso: String) -> Double? {
        let tParts = iso.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        guard tParts.count == 2, tParts[0].count == 10 else { return nil }
        let dateParts = tParts[0].split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3,
              (1...12).contains(dateParts[1]),
              (1...31).contains(dateParts[2]) else { return nil }
        let dayNum = AnalyticsEngine.daysFromCivil(year: dateParts[0], month: dateParts[1], day: dateParts[2])

        var time = String(tParts[1])
        if time.hasSuffix("Z") { time.removeLast() }
        var fraction = 0.0
        if let dot = time.firstIndex(of: ".") {
            let fracText = time[time.index(after: dot)...]
            time = String(time[..<dot])
            // Fractional seconds are optional and position-valued: parse as 0.f
            if !fracText.isEmpty {
                guard let f = Double("0." + fracText) else { return nil }
                fraction = f
            }
        }
        let hms = time.split(separator: ":").compactMap { Int($0) }
        guard hms.count == 3,
              (0...23).contains(hms[0]),
              (0...59).contains(hms[1]),
              (0...59).contains(hms[2]) else { return nil }
        return Double(dayNum) * 86400.0
            + Double(hms[0]) * 3600.0
            + Double(hms[1]) * 60.0
            + Double(hms[2])
            + fraction
    }

    /// Median of a list (sorted; even count averages the two middle values).
    /// nil for an empty input.
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2.0
    }

    // MARK: Session qualification

    /// A session is QUALIFYING ("CompletedSet-bearing", #4 trigger line 1) iff
    /// it carries ≥1 live completed_set row with status = 'completed'. The DAO
    /// layer filters tombstones (INV-3) before values reach this engine.
    public static func qualifyingSessionIds(
        sessions: [AnalyticsSession],
        sets: [AnalyticsSet]
    ) -> Set<String> {
        var completedBySession: Set<String> = []
        for set in sets where set.status == "completed" {
            completedBySession.insert(set.sessionId)
        }
        return Set(sessions.map(\.id)).intersection(completedBySession)
    }

    /// Completed-set count per session (any status is NOT enough — status
    /// 'completed' rows only, the "sets logged" number of the speed proxies).
    static func completedCountBySession(sets: [AnalyticsSet]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for set in sets where set.status == "completed" {
            counts[set.sessionId, default: 0] += 1
        }
        return counts
    }

    // MARK: (a) Weekly session counts + the ≥2-session week streak

    /// Per-ISO-week qualifying-session counts of `startedAt`, ascending; weeks
    /// with zero qualifying sessions are absent (INV-A3 — no zero-fill).
    public static func weeklySessionCounts(
        sessions: [AnalyticsSession],
        sets: [AnalyticsSet]
    ) -> [WeekSessionCount] {
        let qualifying = qualifyingSessionIds(sessions: sessions, sets: sets)
        var byWeek: [String: Int] = [:]
        for session in sessions where qualifying.contains(session.id) {
            byWeek[AnalyticsEngine.isoWeekKey(AnalyticsEngine.utcDay(session.startedAt)), default: 0] += 1
        }
        return byWeek.keys.sorted().map { WeekSessionCount(week: $0, sessionCount: byWeek[$0] ?? 0) }
    }

    /// ISO weeks carrying ≥ gateSessionsPerWeek qualifying sessions.
    public static func qualifyingWeeks(
        sessions: [AnalyticsSession],
        sets: [AnalyticsSet]
    ) -> Set<String> {
        Set(weeklySessionCounts(sessions: sessions, sets: sets)
            .filter { $0.sessionCount >= gateSessionsPerWeek }
            .map(\.week))
    }

    /// Qualifying-session count of the ISO week containing `today` (the
    /// dashboard's "this week: n of 2"; a partial week counts as it stands).
    public static func currentWeekSessionCount(
        sessions: [AnalyticsSession],
        sets: [AnalyticsSet],
        today: String
    ) -> Int {
        let week = AnalyticsEngine.isoWeekKey(today)
        return weeklySessionCounts(sessions: sessions, sets: sets)
            .first { $0.week == week }?.sessionCount ?? 0
    }

    /// Consecutive ≥2-session ISO weeks ending at the present anchor —
    /// BR-001's yesterday-anchor generalized to weeks: anchor = the week
    /// containing `today` if it qualifies, else the PREVIOUS week (a rest week
    /// in progress must not zero a live run); 0 when neither qualifies.
    public static func consecutiveQualifyingWeeks(
        sessions: [AnalyticsSession],
        sets: [AnalyticsSet],
        today: String
    ) -> Int {
        let weeks = qualifyingWeeks(sessions: sessions, sets: sets)
        guard !weeks.isEmpty else { return 0 }

        func weekKey(containing dayNumber: Int) -> String {
            AnalyticsEngine.isoWeekKey(AnalyticsEngine.dayString(dayNumber))
        }
        func previousWeekKey(of dayNumber: Int) -> String {
            // Monday of the week containing dayNumber, minus one day, is
            // inside the previous ISO week (weeks are Monday-start).
            let monday = dayNumber - AnalyticsEngine.mondayIndex(dayNumber)
            return weekKey(containing: monday - 1)
        }

        let todayNum = AnalyticsEngine.dayNumber(today)
        var anchorWeek = weekKey(containing: todayNum)
        if !weeks.contains(anchorWeek) {
            anchorWeek = previousWeekKey(of: todayNum)
            guard weeks.contains(anchorWeek) else { return 0 }
        }

        // Walk backwards week by week. Cursor stays a day inside the current
        // anchor week; each step jumps to the previous week's Monday−1 day.
        var cursorDay = todayNum
        while weekKey(containing: cursorDay) != anchorWeek {
            cursorDay -= 1
        }
        var count = 0
        var week = anchorWeek
        while weeks.contains(week) {
            count += 1
            let monday = cursorDay - AnalyticsEngine.mondayIndex(cursorDay)
            cursorDay = monday - 1
            week = weekKey(containing: cursorDay)
        }
        return count
    }

    // MARK: (b) Logging-speed proxies

    /// median seconds-per-completed-set (completedAt deltas within a session,
    /// first set excluded) + median session-duration ÷ set-count.
    public static func loggingSpeedProxy(
        sessions: [AnalyticsSession],
        sets: [AnalyticsSet]
    ) -> SpeedProxy {
        // Group completed, timestamped sets per session, ordered by completedAt
        // (tie-break id for determinism — sortOrder is not authoritative for
        // logged-at order once edits land).
        var bySession: [String: [AnalyticsSet]] = [:]
        for set in sets where set.status == "completed" && set.completedAt != nil {
            bySession[set.sessionId, default: []].append(set)
        }

        var deltas: [Double] = []
        for sessionSets in bySession.values {
            let ordered = sessionSets.sorted { a, b in
                if a.completedAt != b.completedAt { return (a.completedAt ?? "") < (b.completedAt ?? "") }
                return a.id < b.id
            }
            var prev: Double? = nil
            for set in ordered {
                guard let t = epochSeconds(set.completedAt ?? "") else { continue }
                if let p = prev { deltas.append(t - p) }   // first set excluded
                prev = t
            }
        }

        // Whole-session pace: (endedAt − startedAt) ÷ completed count, sessions
        // with both bounds and ≥1 completed set; median across sessions.
        var perSessionPace: [Double] = []
        for session in sessions {
            guard let ended = session.endedAt,
                  let start = epochSeconds(session.startedAt),
                  let end = epochSeconds(ended),
                  end >= start else { continue }
            let completed = bySession[session.id]?.count ?? 0
            guard completed > 0 else { continue }
            perSessionPace.append((end - start) / Double(completed))
        }

        return SpeedProxy(
            medianSecondsPerSet: median(deltas),
            medianSessionSecondsPerSet: median(perSessionPace)
        )
    }

    // MARK: (c) Retention

    /// Distinct UTC days carrying ≥1 open event, sorted ascending (the raw
    /// retention timeline; two opens the same day count once).
    public static func openDays(events: [ValidationOpenEvent]) -> [String] {
        Set(events.map { AnalyticsEngine.utcDay($0.openedAt) }).sorted()
    }

    /// Distinct open-days per ISO week, ascending; zero-event weeks absent
    /// (INV-A3).
    public static func weeklyRetention(events: [ValidationOpenEvent]) -> [WeekRetention] {
        var byWeek: [String: Set<String>] = [:]
        for event in events {
            let day = AnalyticsEngine.utcDay(event.openedAt)
            byWeek[AnalyticsEngine.isoWeekKey(day), default: []].insert(day)
        }
        return byWeek.keys.sorted().map { WeekRetention(week: $0, distinctOpenDays: byWeek[$0]?.count ?? 0) }
    }

    /// Distinct open-days inside the ISO week containing `today`.
    public static func currentWeekOpenDays(events: [ValidationOpenEvent], today: String) -> Int {
        let week = AnalyticsEngine.isoWeekKey(today)
        return weeklyRetention(events: events).first { $0.week == week }?.distinctOpenDays ?? 0
    }

    // MARK: (d) Gate evaluation

    /// PASS requires ALL THREE of #4's trigger conditions simultaneously:
    ///   1. weekStreak ≥ gateWeeksRequired (derived — sessions/sets above);
    ///   2. displacementConfirmed — builder attests weeks 5–8 logged ZERO Hevy
    ///      sessions (manual; not derivable on-device);
    ///   3. retentionConfirmed — builder answers "would you return to Hevy for
    ///      next week?" with NO at the week-8 checkpoint (manual; the
    ///      installed-and-opened half rides app_open_event above).
    /// NOT-STARTED = no qualifying week ever; otherwise IN-PROGRESS.
    public static func evaluateGate(
        sessions: [AnalyticsSession],
        sets: [AnalyticsSet],
        today: String,
        displacementConfirmed: Bool,
        retentionConfirmed: Bool
    ) -> GateEvaluation {
        let hasAnyQualifyingWeek = !qualifyingWeeks(sessions: sessions, sets: sets).isEmpty
        let streak = consecutiveQualifyingWeeks(sessions: sessions, sets: sets, today: today)
        let streakMet = streak >= gateWeeksRequired

        let status: GateStatus
        if !hasAnyQualifyingWeek {
            status = .notStarted
        } else if streakMet && displacementConfirmed && retentionConfirmed {
            status = .pass
        } else {
            status = .inProgress
        }
        return GateEvaluation(
            status: status,
            weekStreak: streak,
            streakConditionMet: streakMet,
            displacementConfirmed: displacementConfirmed,
            retentionConfirmed: retentionConfirmed,
            weeksRequired: gateWeeksRequired,
            sessionsPerWeekRequired: gateSessionsPerWeek
        )
    }
}
