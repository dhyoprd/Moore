// Ticket #43 — seam-1 coverage for ValidationMetricsEngine (the 8-week gate).
// Pure engine tests — no DB, no GRDB; the Node verifier (VerifyValidation.mjs)
// runs the same rules against SQLite through the JS mirror. Vectors mirror the
// fixture pack Tests/MooreAnalyticsTests/Fixtures/validation-*.json.

import XCTest
@testable import MooreAnalytics

final class ValidationMetricsEngineTests: XCTestCase {

    private func session(_ id: String, started: String, ended: String? = nil) -> AnalyticsSession {
        AnalyticsSession(id: id, name: nil, startedAt: started, endedAt: ended)
    }

    private func completedSet(_ id: String, session: String, at: String? = nil) -> AnalyticsSet {
        AnalyticsSet(
            id: id, sessionId: session, exerciseId: "ex", sortOrder: 0,
            status: "completed", setClass: "work", completedAt: at
        )
    }

    // MARK: Weekly counts + streak (fixture 02/03/04 parity)

    func testWeekStreakCountsConsecutiveTwoSessionWeeks() {
        // W31/W32/W33 of 2026 each carry 2 qualifying sessions; today is W33.
        var sessions: [AnalyticsSession] = []
        var sets: [AnalyticsSet] = []
        let days = ["2026-07-27", "2026-08-03", "2026-08-10"]   // Mon of W31, W32, W33
        for (i, day) in days.enumerated() {
            for j in 0..<2 {
                let sid = "s\(i)-\(j)"
                sessions.append(session(sid, started: "\(day)T10:00:00Z", ended: "\(day)T11:00:00Z"))
                sets.append(completedSet("set\(i)-\(j)", session: sid))
            }
        }
        XCTAssertEqual(
            ValidationMetricsEngine.consecutiveQualifyingWeeks(sessions: sessions, sets: sets, today: "2026-08-12"),
            3
        )
        XCTAssertEqual(ValidationMetricsEngine.currentWeekSessionCount(sessions: sessions, sets: sets, today: "2026-08-12"), 2)
    }

    func testOneSessionWeekBreaksTheStreak() {
        // W30 + W31 qualify (2 sessions), W32 has ONE session, W33 qualifies.
        var sessions: [AnalyticsSession] = []
        var sets: [AnalyticsSet] = []
        for day in ["2026-07-20", "2026-07-27"] {                // W30, W31
            for j in 0..<2 {
                let sid = "s\(day)-\(j)"
                sessions.append(session(sid, started: "\(day)T10:00:00Z"))
                sets.append(completedSet("set\(day)-\(j)", session: sid))
            }
        }
        sessions.append(session("s-broken", started: "2026-08-03T10:00:00Z"))   // W32 ×1
        sets.append(completedSet("set-broken", session: "s-broken"))
        sessions.append(session("s-now-a", started: "2026-08-10T10:00:00Z"))    // W33 ×2
        sessions.append(session("s-now-b", started: "2026-08-11T10:00:00Z"))
        sets.append(completedSet("set-now-a", session: "s-now-a"))
        sets.append(completedSet("set-now-b", session: "s-now-b"))

        XCTAssertEqual(
            ValidationMetricsEngine.consecutiveQualifyingWeeks(sessions: sessions, sets: sets, today: "2026-08-12"),
            1
        )
    }

    // MARK: Gate evaluation

    func testGateNotStartedWithoutQualifyingWeek() {
        let sessions = [session("s1", started: "2026-08-10T10:00:00Z")]
        let sets = [completedSet("a", session: "s1")]
        let gate = ValidationMetricsEngine.evaluateGate(
            sessions: sessions, sets: sets, today: "2026-08-12",
            displacementConfirmed: true, retentionConfirmed: true
        )
        XCTAssertEqual(gate.status, .notStarted)
        XCTAssertEqual(gate.weekStreak, 0)
    }

    func testGatePassRequiresStreakAndBothManualConfirmations() {
        // 8 consecutive qualifying weeks W26..W33.
        var sessions: [AnalyticsSession] = []
        var sets: [AnalyticsSet] = []
        let mondays = [
            "2026-06-22", "2026-06-29", "2026-07-06", "2026-07-13",
            "2026-07-20", "2026-07-27", "2026-08-03", "2026-08-10",
        ]
        for (i, day) in mondays.enumerated() {
            for j in 0..<2 {
                let sid = "s\(i)-\(j)"
                sessions.append(session(sid, started: "\(day)T10:00:00Z"))
                sets.append(completedSet("set\(i)-\(j)", session: sid))
            }
        }
        let bothConfirmed = ValidationMetricsEngine.evaluateGate(
            sessions: sessions, sets: sets, today: "2026-08-12",
            displacementConfirmed: true, retentionConfirmed: true
        )
        XCTAssertEqual(bothConfirmed.status, .pass)
        XCTAssertEqual(bothConfirmed.weekStreak, 8)
        XCTAssertTrue(bothConfirmed.streakConditionMet)

        // Same data, one manual confirmation missing → still in progress.
        let missingOne = ValidationMetricsEngine.evaluateGate(
            sessions: sessions, sets: sets, today: "2026-08-12",
            displacementConfirmed: true, retentionConfirmed: false
        )
        XCTAssertEqual(missingOne.status, .inProgress)
    }

    // MARK: Speed proxy math (fixture 05 parity)

    func testSpeedProxyMedianMath() {
        let sessions = [
            session("sA", started: "2026-08-10T10:00:00Z", ended: "2026-08-10T10:03:20Z"),  // 200s / 4 sets
            session("sB", started: "2026-08-11T10:00:00Z", ended: "2026-08-11T10:02:00Z"),  // 120s / 2 sets
        ]
        let sets = [
            // sA: completedAt t0, +30, +90, +100 → deltas 30, 60, 10.
            completedSet("a1", session: "sA", at: "2026-08-10T10:00:00Z"),
            completedSet("a2", session: "sA", at: "2026-08-10T10:00:30Z"),
            completedSet("a3", session: "sA", at: "2026-08-10T10:01:30Z"),
            completedSet("a4", session: "sA", at: "2026-08-10T10:01:40Z"),
            // sB: one delta of 45s.
            completedSet("b1", session: "sB", at: "2026-08-11T10:00:00Z"),
            completedSet("b2", session: "sB", at: "2026-08-11T10:00:45Z"),
        ]
        let proxy = ValidationMetricsEngine.loggingSpeedProxy(sessions: sessions, sets: sets)
        // Pooled deltas [10, 30, 45, 60] → median (30 + 45) / 2 = 37.5.
        XCTAssertEqual(proxy.medianSecondsPerSet, 37.5, accuracy: 1e-9)
        // Session pace: 200/4 = 50, 120/2 = 60 → median 55.
        XCTAssertEqual(proxy.medianSessionSecondsPerSet, 55, accuracy: 1e-9)
    }

    func testSpeedProxyEmptyWhenSingleSetSessionsOnly() {
        let sessions = [session("s1", started: "2026-08-10T10:00:00Z", ended: "2026-08-10T10:05:00Z")]
        let sets = [completedSet("a", session: "s1", at: "2026-08-10T10:00:00Z")]
        let proxy = ValidationMetricsEngine.loggingSpeedProxy(sessions: sessions, sets: sets)
        XCTAssertNil(proxy.medianSecondsPerSet)                     // first set excluded → no deltas
        XCTAssertEqual(proxy.medianSessionSecondsPerSet, 300, accuracy: 1e-9)
    }

    // MARK: Retention (fixture 06 parity)

    func testRetentionCountsDistinctDaysPerWeek() {
        let events = [
            ValidationOpenEvent(id: "e1", openedAt: "2026-08-10T08:00:00Z"),
            ValidationOpenEvent(id: "e2", openedAt: "2026-08-10T20:00:00Z"),  // same day → one
            ValidationOpenEvent(id: "e3", openedAt: "2026-08-11T08:00:00Z"),
            ValidationOpenEvent(id: "e4", openedAt: "2026-08-17T08:00:00Z"),  // W34
        ]
        let weeks = ValidationMetricsEngine.weeklyRetention(events: events)
        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks[0], WeekRetention(week: "2026-W33", distinctOpenDays: 2))
        XCTAssertEqual(weeks[1], WeekRetention(week: "2026-W34", distinctOpenDays: 1))
        XCTAssertEqual(ValidationMetricsEngine.currentWeekOpenDays(events: events, today: "2026-08-12"), 2)
    }

    // MARK: Timestamp math

    func testEpochSecondsClosedForm() {
        XCTAssertEqual(ValidationMetricsEngine.epochSeconds("1970-01-01T00:00:00Z"), 0)
        XCTAssertEqual(ValidationMetricsEngine.epochSeconds("2026-08-10T10:00:30Z"),
                       Double(AnalyticsEngine.dayNumber("2026-08-10")) * 86400 + 36030)
        XCTAssertEqual(ValidationMetricsEngine.epochSeconds("2026-08-10T10:00:30.500Z"),
                       Double(AnalyticsEngine.dayNumber("2026-08-10")) * 86400 + 36030.5,
                       accuracy: 1e-9)
        XCTAssertNil(ValidationMetricsEngine.epochSeconds("not-a-timestamp"))
        XCTAssertNil(ValidationMetricsEngine.epochSeconds("2026-13-40T99:99:99Z"))
    }

    func testMedianEvenAndOdd() {
        XCTAssertEqual(ValidationMetricsEngine.median([30, 60, 10]), 30)
        XCTAssertEqual(ValidationMetricsEngine.median([10, 30, 45, 60]), 37.5)
        XCTAssertNil(ValidationMetricsEngine.median([]))
    }
}
