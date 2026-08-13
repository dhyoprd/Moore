// Ticket #43 — Self-validation surface state (the 8-week gate dashboard).
// Foundation-only (@Observable, no SwiftUI) so it parses/verifies off-Mac; the
// SwiftUI layer in Views/ binds to this surface and stays thin.
//
// Architecture: the model DRIVES the seams, never reimplements them —
//   • AnalyticsDAO.fetchSessions/fetchSets — the frozen SC-analytics read seam
//     supplies the session/set substrate (INV-A1 intact: still read-only there).
//   • ValidationDAO — the #43 storage seam (app_open_event, validation_baseline,
//     the two manual gate confirmations in app_setting).
//   • ValidationMetricsEngine — ALL math (week counts, streak, speed proxies,
//     retention, gate verdict) is the engine's closed-form derivation.
//
// App-open recording: one row per app FOREGROUND (the 0012 table contract).
// Boot records the first one (AppDependencies.boot); later foregrounds ride
// AppState.scenePhaseChanged → recordAppOpenIfNeeded(). refresh() ALSO calls
// recordAppOpenIfNeeded() first — "records on read" — and the once-per-
// foreground flag makes that idempotent, so a read can never double-record.
//
// Privacy: every input lives in the on-device SQLite file. No network, no
// third-party analytics — the gate is measured from the builder's own data
// (AC: nothing phones home).

import Foundation
import Observation
import MooreAnalytics

// MARK: - ValidationModel

@Observable
public final class ValidationModel {

    // MARK: Observable surface (the views render ONLY this)

    // Streak/usage (gate condition 1, derived).
    public private(set) var currentWeekCount = 0
    public private(set) var weekStreak = 0
    public private(set) var weeklyCounts: [WeekSessionCount] = []

    // Logging speed vs Hevy baseline (derived proxy + stored reference).
    public private(set) var speedProxy: SpeedProxy?
    public private(set) var baseline: ValidationBaseline?
    /// The baseline entry field's draft (committed by saveBaseline()).
    public var baselineDraft = ""

    // Retention (app-open cadence, derived).
    public private(set) var retentionWeeks: [WeekRetention] = []
    public private(set) var currentWeekOpenDays = 0
    public private(set) var totalOpenDays = 0

    // The gate card.
    public private(set) var gate: GateEvaluation?

    // MARK: Render-ready copy (views never format)

    public var currentWeekCountText: String {
        UICopy.validationWeekCount(currentWeekCount)
    }
    public var weekStreakText: String {
        UICopy.validationStreakCount(weekStreak)
    }
    public var speedCurrentText: String {
        guard let secs = speedProxy?.medianSecondsPerSet else { return UICopy.validationSpeedEmpty }
        return UICopy.validationSpeedCurrent(Self.secondsText(secs))
    }
    public var speedBaselineText: String {
        guard let baseline else { return UICopy.validationBaselineEmpty }
        return UICopy.validationSpeedBaseline(Self.secondsText(baseline.value))
    }
    public var retentionWeekText: String {
        UICopy.validationRetentionWeek(currentWeekOpenDays)
    }
    public var retentionTotalText: String {
        UICopy.validationRetentionTotal(totalOpenDays)
    }
    public var gateStatusText: String {
        switch gate?.status {
        case .pass: return UICopy.validationGatePass
        case .inProgress: return UICopy.validationGateInProgress
        case .notStarted, nil: return UICopy.validationGateNotStarted
        }
    }
    public var displacementConfirmed: Bool { gate?.displacementConfirmed ?? false }
    public var retentionConfirmed: Bool { gate?.retentionConfirmed ?? false }

    // MARK: Seams (driven, never reimplemented)

    private let validationDAO: ValidationDAO
    private let analyticsDAO: AnalyticsDAO

    /// Once-per-foreground guard for the app-open row (reset on background).
    private var openRecordedForCurrentForeground = false

    public init(validationDAO: ValidationDAO, analyticsDAO: AnalyticsDAO) {
        self.validationDAO = validationDAO
        self.analyticsDAO = analyticsDAO
    }

    // MARK: App-open recording (one row per foreground)

    /// Idempotent per foreground: boot and every foreground transition call
    /// this; refresh() calls it too ("records on read") and the flag absorbs
    /// the repeat.
    public func recordAppOpenIfNeeded() {
        guard !openRecordedForCurrentForeground else { return }
        do {
            try validationDAO.recordAppOpen(at: Self.utcNow())
            openRecordedForCurrentForeground = true
        } catch {
            // Storage hiccup: the retention timeline loses one event; the
            // dashboard still renders from whatever reads succeed.
        }
    }

    /// Scene backgrounded: the NEXT foreground is a new app-open event.
    public func markBackgrounded() {
        openRecordedForCurrentForeground = false
    }

    // MARK: Refresh (cold re-read; every number recomputes at read time)

    public func refresh() {
        recordAppOpenIfNeeded()
        let today = Self.utcToday()
        do {
            let sessions = try analyticsDAO.fetchSessions()
            let sets = try analyticsDAO.fetchSets()
            let events = try validationDAO.fetchOpenEvents()
            let displacement = try validationDAO.fetchConfirmation(key: ValidationDAO.displacementConfirmedKey)
            let retention = try validationDAO.fetchConfirmation(key: ValidationDAO.retentionConfirmedKey)
            baseline = try validationDAO.fetchBaseline(metricKey: ValidationDAO.hevySpeedBaselineKey)

            weeklyCounts = ValidationMetricsEngine.weeklySessionCounts(sessions: sessions, sets: sets)
            currentWeekCount = ValidationMetricsEngine.currentWeekSessionCount(sessions: sessions, sets: sets, today: today)
            weekStreak = ValidationMetricsEngine.consecutiveQualifyingWeeks(sessions: sessions, sets: sets, today: today)
            speedProxy = ValidationMetricsEngine.loggingSpeedProxy(sessions: sessions, sets: sets)
            retentionWeeks = ValidationMetricsEngine.weeklyRetention(events: events)
            currentWeekOpenDays = ValidationMetricsEngine.currentWeekOpenDays(events: events, today: today)
            totalOpenDays = ValidationMetricsEngine.openDays(events: events).count
            gate = ValidationMetricsEngine.evaluateGate(
                sessions: sessions,
                sets: sets,
                today: today,
                displacementConfirmed: displacement,
                retentionConfirmed: retention
            )
        } catch {
            // Storage hiccup → honest empty state, never a crash.
            currentWeekCount = 0
            weekStreak = 0
            weeklyCounts = []
            speedProxy = nil
            baseline = nil
            retentionWeeks = []
            currentWeekOpenDays = 0
            totalOpenDays = 0
            gate = nil
        }
    }

    // MARK: Manual confirmations (#4 trigger lines 2–3 — human-judged)

    public func setDisplacementConfirmed(_ confirmed: Bool) {
        persistConfirmation(key: ValidationDAO.displacementConfirmedKey, confirmed: confirmed)
    }

    public func setRetentionConfirmed(_ confirmed: Bool) {
        persistConfirmation(key: ValidationDAO.retentionConfirmedKey, confirmed: confirmed)
    }

    private func persistConfirmation(key: String, confirmed: Bool) {
        do {
            try validationDAO.setConfirmation(key: key, confirmed: confirmed, at: Self.utcNow())
        } catch {
            // fall through — refresh() re-reads the stored truth
        }
        refresh()
    }

    // MARK: Baseline entry

    /// Commits baselineDraft as the live Hevy speed baseline (s/set). Invalid
    /// or empty drafts are ignored — the field keeps its text for correction.
    public func saveBaseline() {
        let normalized = baselineDraft.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return }
        do {
            try validationDAO.upsertBaseline(
                metricKey: ValidationDAO.hevySpeedBaselineKey,
                value: value,
                unit: "sec",
                recordedAt: Self.utcNow(),
                at: Self.utcNow()
            )
            baselineDraft = ""
        } catch {
            // keep the draft; the next attempt can retry
            return
        }
        refresh()
    }

    // MARK: Internals

    static func secondsText(_ seconds: Double) -> String {
        String(format: "%.0f s/set", seconds)
    }

    /// UTC day string of "now" — calendar math is UTC-day based (SC-analytics
    /// §3b), never the local timezone.
    static func utcToday() -> String {
        String(ISO8601DateFormatter().string(from: Date()).prefix(10))
    }

    /// Full ISO-8601 UTC timestamp of "now" (event/row stamps).
    static func utcNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
