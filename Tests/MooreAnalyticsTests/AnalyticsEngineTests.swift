// contractId: SC-analytics @1.0.0
// §7 seam-1 coverage (ticket AC: "Seam-1 tests cover: Epley 1RM trend math,
// tonnage aggregation with warmup exclusion, muscle split sums, streak
// calculation with cross-week boundary"). Pure engine tests — no DB, no GRDB;
// the Node verifier (VerifyAnalytics.mjs) runs the same rules against SQLite.

import XCTest
@testable import MooreAnalytics

final class AnalyticsEngineTests: XCTestCase {

    private func session(_ id: String, _ day: String) -> AnalyticsSession {
        AnalyticsSession(id: id, name: nil, startedAt: "\(day)T10:00:00Z", endedAt: "\(day)T11:00:00Z")
    }

    private func set(_ id: String, session: String, exercise: String,
                     weight: Double?, reps: Int?, status: String = "completed",
                     setClass: String? = "work") -> AnalyticsSet {
        AnalyticsSet(
            id: id, sessionId: session, exerciseId: exercise, sortOrder: 0,
            actualWeight: weight, actualReps: reps,
            status: status, setClass: setClass, completedAt: nil
        )
    }

    // MARK: Epley 1RM trend math (BR-002)

    func testEpleyFormula() {
        XCTAssertEqual(AnalyticsEngine.epley1RM(weight: 60, reps: 5), 70, accuracy: 1e-9)
        XCTAssertEqual(AnalyticsEngine.epley1RM(weight: 100, reps: 3), 110, accuracy: 1e-9)
    }

    func testTrendPointIsMaxEpleyNotMaxWeight() {
        let sessions = [session("s1", "2026-08-10")]
        let sets = [
            set("a", session: "s1", exercise: "ex", weight: 100, reps: 3),   // 110
            set("b", session: "s1", exercise: "ex", weight: 90, reps: 8),    // 114 ← wins
            set("c", session: "s1", exercise: "ex", weight: 120, reps: 1, setClass: "warmup"), // invisible
        ]
        let points = AnalyticsEngine.epleyTrend(
            sessions: sessions, sets: sets, exerciseId: "ex",
            today: "2026-08-12", rangeDays: 30
        )
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].value, 114, accuracy: 1e-9)
        XCTAssertEqual(points[0].segment, 0)
    }

    func testTrendGapOverSevenDaysBreaksLine() {
        let sessions = [
            session("s1", "2026-07-01"),
            session("s2", "2026-07-08"),   // gap 7 → connected
            session("s3", "2026-07-17"),   // gap 9 → new segment
        ]
        let sets = [
            set("a", session: "s1", exercise: "ex", weight: 60, reps: 5),
            set("b", session: "s2", exercise: "ex", weight: 62, reps: 5),
            set("c", session: "s3", exercise: "ex", weight: 65, reps: 5),
        ]
        let points = AnalyticsEngine.epleyTrend(
            sessions: sessions, sets: sets, exerciseId: "ex",
            today: "2026-08-12", rangeDays: 60
        )
        XCTAssertEqual(points.map(\.segment), [0, 0, 1])
        XCTAssertEqual(points.count, 3) // no zero-value interpolation (INV-A3)
    }

    // MARK: Tonnage aggregation with warmup exclusion (BR-003)

    func testWeeklyTonnageExcludesWarmupsAndNonCompleted() {
        let sessions = [session("s1", "2026-08-10")]
        let sets = [
            set("warm", session: "s1", exercise: "ex", weight: 20, reps: 15, setClass: "warmup"),
            set("w1", session: "s1", exercise: "ex", weight: 100, reps: 5),
            set("w2", session: "s1", exercise: "ex", weight: 100, reps: 3, setClass: nil), // NULL ⇔ work
            set("f", session: "s1", exercise: "ex", weight: 100, reps: 4, status: "failed"),
            set("d", session: "s1", exercise: "ex", weight: nil, reps: nil, status: "dropped", setClass: nil),
        ]
        let weeks = AnalyticsEngine.weeklyTonnage(
            sessions: sessions, sets: sets, today: "2026-08-12", rangeDays: 30
        )
        XCTAssertEqual(weeks.count, 1)
        XCTAssertEqual(weeks[0].week, "2026-W33")
        XCTAssertEqual(weeks[0].tonnage, 800, accuracy: 1e-9)
    }

    // MARK: Muscle split sums (BR-004)

    func testMuscleSplitSumsToOneHundred() {
        let sessions = [session("s1", "2026-08-10")]
        let exercises = [
            ExerciseInfo(id: "bench", name: "Bench", category: "chest"),
            ExerciseInfo(id: "squat", name: "Squat", category: "quads"),
            ExerciseInfo(id: "crunch", name: "Crunch", category: "core"),
        ]
        let sets = [
            set("a", session: "s1", exercise: "bench", weight: 100, reps: 3),
            set("b", session: "s1", exercise: "squat", weight: 80, reps: 5),
            set("c", session: "s1", exercise: "crunch", weight: 20, reps: 15),
        ]
        let buckets = AnalyticsEngine.muscleSplit(
            sessions: sessions, sets: sets, exercises: exercises,
            today: "2026-08-12", rangeDays: 30
        )
        XCTAssertEqual(buckets.map(\.bucket), ["upper", "lower", "other"])
        let sum = buckets.reduce(0) { $0 + $1.pct }
        XCTAssertEqual(sum, 100, accuracy: 0.1)
    }

    // MARK: Streak with cross-week boundary (BR-001)

    func testStreakCountsThroughWeekBoundaryAndResetsOnGap() {
        // Fri 08-07, Sat 08-08, Sun 08-09 are ISO week W32; Mon 08-10 is W33 —
        // the run crosses the boundary and still counts 4.
        let sessions = [
            session("s1", "2026-08-07"),
            session("s2", "2026-08-08"),
            session("s3", "2026-08-09"),
            session("s4", "2026-08-10"),
            session("s5", "2026-08-12"),   // dropped-only day 08-11 in between
        ]
        let sets = [
            set("a", session: "s1", exercise: "ex", weight: 60, reps: 5),
            set("b", session: "s2", exercise: "ex", weight: 60, reps: 5),
            set("c", session: "s3", exercise: "ex", weight: 60, reps: 5),
            set("d", session: "s4", exercise: "ex", weight: 60, reps: 5),
            AnalyticsSet(id: "e", sessionId: "s5", exerciseId: "ex", sortOrder: 0,
                         status: "dropped", setClass: nil, completedAt: nil),
        ]
        let days = AnalyticsEngine.qualifyingDays(sessions: sessions, sets: sets)
        XCTAssertEqual(days, ["2026-08-07", "2026-08-08", "2026-08-09", "2026-08-10"])
        XCTAssertEqual(AnalyticsEngine.currentStreak(qualifyingDays: days, today: "2026-08-10"), 4)
        XCTAssertEqual(AnalyticsEngine.currentStreak(qualifyingDays: days, today: "2026-08-11"), 4) // yesterday anchor
        XCTAssertEqual(AnalyticsEngine.currentStreak(qualifyingDays: days, today: "2026-08-20"), 0) // gap kills it
    }

    // MARK: Calendar math sanity (closed-form, mirrored in VerifyAnalytics.mjs)

    func testIsoWeekKeys() {
        XCTAssertEqual(AnalyticsEngine.isoWeekKey("2026-08-10"), "2026-W33")
        XCTAssertEqual(AnalyticsEngine.isoWeekKey("2026-01-01"), "2026-W01")
        XCTAssertEqual(AnalyticsEngine.isoWeekKey("2025-12-29"), "2026-W01")
    }
}
