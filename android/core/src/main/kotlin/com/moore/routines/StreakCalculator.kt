// contractId: SC-routines @1.0.0
// BR-005 streak chip: hidden when zero completed sessions; else the count of
// consecutive calendar weeks — ending at the most recent week that contains a
// session — that each contain ≥1 completed session. The current week, if it
// contains a session, counts even though it is partial (V10 "rounds up").
// Derived at read time, never persisted (INV-R4 / #3 invariant 5).
// Mechanical Kotlin port of Sources/MooreRoutines/StreakCalculator.swift.
// Weeks are ISO-8601 Monday-anchored (deterministic across locales — the Swift
// original takes a Calendar; the Kotlin port fixes the week start so identical
// inputs give identical outputs on every Android device).
package com.moore.routines

import com.moore.analytics.AnalyticsEngine

object StreakCalculator {

    private const val WEEK_DAYS = 7
    // 1970-01-01 (day 0) was a Thursday ⇒ Monday index of day 0 is 3.
    private fun weekStartDayNumber(dayNumber: Int): Int = dayNumber - AnalyticsEngine.mondayIndex(dayNumber)

    /// - completedAtDates: the endedAt (ISO-8601 UTC) of every completed session
    ///   (endedAt IS NOT NULL), in any order. Caller supplies them pre-filtered.
    /// - now: the instant the streak is evaluated (the streak is anchored to the
    ///   most recent session week, so a broken current week does not zero it out).
    /// - Returns: null when completedAtDates is empty (chip hidden, V7); else the
    ///   consecutive-week count ≥ 1 ending at the most recent active week.
    fun streakCount(completedAtDates: List<String>, now: String): Int? {
        if (completedAtDates.isEmpty()) return null   // BR-005: hidden until first

        val weeksWithSession = completedAtDates
            .map { weekStartDayNumber(AnalyticsEngine.dayNumber(AnalyticsEngine.utcDay(it))) }
            .toSet()

        // Anchor at the most recent week that actually contains a session, then
        // count consecutive weeks backwards. If that anchor is the current week,
        // the current (partial) week rounds up into the count (V10).
        var cursor = weeksWithSession.max()
        var count = 0
        while (weeksWithSession.contains(cursor)) {
            count += 1
            cursor -= WEEK_DAYS
        }
        return count
    }
}
