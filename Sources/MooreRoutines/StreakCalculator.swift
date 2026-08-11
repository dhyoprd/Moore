// contractId: SC-routines @1.0.0
// BR-005 streak chip: hidden when zero completed sessions; else the count of
// consecutive calendar weeks — ending at the most recent week that contains a
// session — that each contain ≥1 completed session. The current week, if it
// contains a session, counts even though it is partial (V10 "rounds up").
// Derived at read time, never persisted (INV-R4 / #3 invariant 5).

import Foundation

public enum StreakCalculator {
    /// - Parameter completedAtDates: the `endedAt` of every completed session
    ///   (`endedAt IS NOT NULL`), in any order. Caller supplies them pre-filtered.
    /// - Parameter now: the time the streak is evaluated (kept for signature symmetry
    ///   with callers that pass a fixed clock; the streak is anchored to the most
    ///   recent session week, so a broken current week does not zero it out).
    /// - Returns: nil when `completedAtDates` is empty (chip hidden, V7); else the
    ///   consecutive-week count ≥ 1 ending at the most recent active week.
    public static func streakCount(
        completedAtDates: [Date],
        now: Date,
        calendar: Calendar = .current
    ) -> Int? {
        guard !completedAtDates.isEmpty else { return nil }   // BR-005: hidden until first

        func startOfWeek(_ d: Date) -> Date {
            calendar.dateInterval(of: .weekOfYear, for: d)?.start ?? d
        }
        let weeksWithSession = Set(completedAtDates.map { startOfWeek($0) })

        // Anchor at the most recent week that actually contains a session, then count
        // consecutive weeks backwards. If that anchor is the current week, the current
        // (partial) week rounds up into the count (V10); if it is an earlier week, the
        // streak shown is the still-unbroken run as it most recently stood — never a
        // motivational 0 while any history exists (#14).
        var cursor = weeksWithSession.max()!
        var count = 0
        while weeksWithSession.contains(cursor) {
            count += 1
            guard let prev = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }
}
