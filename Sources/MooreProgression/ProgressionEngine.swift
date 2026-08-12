// SC-progression@1.0.0 — pure, rules-based progression engine (no Apple imports).
// Mirrors the contract's BR-001..BR-020 literally; every function closed-form.

import Foundation

// MARK: - Types

public enum Scheme: String, Codable {
    case none, linear, double, holdDuration = "hold-duration"
}

public enum StallAction: String, Codable { case deload, hold, ignore }

public struct Suggestion: Equatable, Codable {
    public var weight: Double?
    public var reps: Int?
    public var durationSec: Int?
    public var touched: [String] = []   // debug: which suggestion path wrote this
}

public struct StallState: Equatable, Codable {
    public var shouldBanner: Bool
    public var bannerCopy: String?
}

public struct ProgressionRecord: Equatable, Codable {
    public var id: String
    public var routineId: String
    public var exerciseId: String
    public var scheme: Scheme = .none
    public var stallCount: Int = 0
    public var stallMuted: Bool = false
    public var nextBannerAt: Int = 3
    public var deloadPending: Bool = false
    public var lastDeloadSessionId: String?
    public var stalledWeight: Double?
    public var stalledReps: Int?
    public var stalledDurationSec: Int?
    public var baselineDurationSec: Int?
    public var updatedAt: Date
}

// MARK: - Aggregates over a reference session

public struct ReferenceSessionSet {
    public var sessionId: String
    public var routineId: String?
    public var status: SetStatus          // completed | failed | dropped
    public var exerciseId: String
    public var setOrdinal: Int
    public var plannedWeight: Double?
    public var plannedReps: Int?
    public var plannedDuration: Int?
    public var actualWeight: Double?
    public var actualReps: Int?
    public var actualDuration: Int?
}

public enum SetStatus: String, Codable { case planned, completed, failed, dropped }

public enum ExerciseMetric { case reps, duration }

// MARK: - Engine

public enum ProgressionEngine {

    // inc(E) per BR-009. Categories land on `exercise.category` (SC-exercises); the
    // upper-biased rule intentionally includes nil/miss cases.
    public static func increment(forExerciseCategory category: String?) -> Double {
        guard let cat = category?.lowercased() else { return 2.5 }
        let lower = ["legs", "quads", "hamstrings", "glutes", "calves"]
        return lower.contains(where: { cat.contains($0) }) ? 5.0 : 2.5
    }

    // round125: nearest 1.25 kg, half-up, floored at 0.
    public static func round125(_ x: Double) -> Double {
        max(0, (x / 1.25).rounded(.toNearestOrAwayFromZero) * 1.25)
    }
    // round25: nearest 2.5 kg, half-up. Used ONLY for deload.
    public static func round25(_ x: Double) -> Double {
        (x / 2.5).rounded(.toNearestOrAwayFromZero) * 2.5
    }

    // Clean-session predicate per BR-006. reps/duration discriminated by metric.
    public static func clean(sets: [ReferenceSessionSet], metric: ExerciseMetric) -> Bool {
        let performed = sets.filter { $0.status != .dropped }
        guard !performed.isEmpty else { return false }
        if performed.contains(where: { $0.status == .failed }) { return false }
        switch metric {
        case .reps:     return performed.allSatisfy { ($0.actualReps ?? 0) >= ($0.plannedReps ?? 0) }
        case .duration: return performed.allSatisfy { ($0.actualDuration ?? 0) >= ($0.plannedDuration ?? 0) }
        }
    }

    // Failed-set donation: MAX(actualReps/actualDuration) across the session's
    // failed sets for E, per BR-007.
    public static func failedMax(sets: [ReferenceSessionSet], metric: ExerciseMetric) -> Int? {
        let fails = sets.filter { $0.status == .failed }
        guard !fails.isEmpty else { return nil }
        switch metric {
        case .reps:     return fails.compactMap { $0.actualReps }.max()
        case .duration: return fails.compactMap { $0.actualDuration }.max()
        }
    }

    // Core suggestion over the LATEST reference the caller resolved (BR-004 windowing
    // happens upstream — this function assumes `reference` is the resolved candidate).
    public static func suggest(
        record: ProgressionRecord,
        reference: [ReferenceSessionSet]?,      // nil = session 1 (BR-003)
        metric: ExerciseMetric,
        category: String?,
        blueprintWeight: Double?,
        blueprintReps: Int?,
        blueprintDurationSec: Int?
    ) -> (suggestion: Suggestion, updatedRecord: ProgressionRecord) {
        var rec = record

        // Session one or unresolvable reference → blueprint verbatim (BR-003).
        guard let reference, !reference.isEmpty else {
            return (suggestion: Suggestion(weight: blueprintWeight, reps: blueprintReps, durationSec: blueprintDurationSec, touched: ["blueprint-verbatim"]), updatedRecord: record)
        }

        // BR-014 deload path.
        if rec.deloadPending, let sw = rec.stalledWeight {
            rec.deloadPending = false
            rec.lastDeloadSessionId = nil   // caller stamps with this session's id
            rec.stallCount = 0
            let w = round25(sw * 0.90)
            switch metric {
            case .reps:     return (suggestion: Suggestion(weight: w, reps: rec.stalledReps, durationSec: nil, touched: ["deload-applied"]), updatedRecord: rec)
            case .duration: return (suggestion: Suggestion(weight: w, reps: nil, durationSec: rec.stalledDurationSec, touched: ["deload-applied"]), updatedRecord: rec)
            }
        }

        // BR-014 re-entry: if the reference session IS the last deload session,
        // unconditionally re-enter at the stalled values.
        if let lastDeload = rec.lastDeloadSessionId,
           let refSessionId = reference.first?.sessionId,
           refSessionId == lastDeload {
            switch metric {
            case .reps:     return (suggestion: Suggestion(weight: rec.stalledWeight, reps: rec.stalledReps, durationSec: nil, touched: ["deload-reentry"]), updatedRecord: rec)
            case .duration: return (suggestion: Suggestion(weight: rec.stalledWeight, reps: nil, durationSec: rec.stalledDurationSec, touched: ["deload-reentry"]), updatedRecord: rec)
            }
        }

        let performed = reference.filter { $0.status != .dropped }
        guard let last = performed.max(by: { $0.setOrdinal < $1.setOrdinal }) else {
            return (suggestion: Suggestion(weight: blueprintWeight, reps: blueprintReps, durationSec: blueprintDurationSec, touched: ["blueprint-verbaim-no-performed"]), updatedRecord: record)
        }
        let W = last.actualWeight
        let P: Int? = (metric == .reps) ? last.plannedReps : last.plannedDuration
        let C = clean(sets: performed, metric: metric)
        let F = failedMax(sets: performed, metric: metric)

        // Not clean → hold weight; target from best effort (BR-007)
        if !C {
            let target: Int?
            if let F { target = (P.map { min($0, F) }) ?? F } else { target = P }
            switch metric {
            case .reps:     return (suggestion: Suggestion(weight: W, reps: target, durationSec: nil, touched: ["hold-weight-from-fail"]), updatedRecord: rec)
            case .duration: return (suggestion: Suggestion(weight: W, reps: nil, durationSec: target, touched: ["hold-weight-from-fail"]), updatedRecord: rec)
            }
        }

        // Clean → scheme math (BR-008)
        let inc = increment(forExerciseCategory: category)
        switch rec.scheme {
        case .none:
            return (suggestion: Suggestion(weight: W, reps: last.actualReps, durationSec: last.actualDuration, touched: ["none-verbatim"]), updatedRecord: rec)
        case .linear:
            guard let W else {
                // Bodyweight: linear degenerates to none per BR-011
                return (suggestion: Suggestion(weight: nil, reps: last.actualReps, durationSec: last.actualDuration, touched: ["linear-degenerate-none"]), updatedRecord: rec)
            }
            return (suggestion: Suggestion(weight: round125(W + inc), reps: last.plannedReps, durationSec: last.plannedDuration, touched: ["linear"]), updatedRecord: rec)
        case .double:
            let pTarget = last.plannedReps ?? 8
            let reps = last.actualReps ?? pTarget
            if reps >= 12, let W {
                return (suggestion: Suggestion(weight: round125(W + inc), reps: 8, durationSec: nil, touched: ["double-ceiling"]), updatedRecord: rec)
            }
            return (suggestion: Suggestion(weight: W, reps: min(reps + 1, 12), durationSec: nil, touched: ["double-reps"]), updatedRecord: rec)
        case .holdDuration:
            let baseline = rec.baselineDurationSec ?? (last.plannedDuration ?? 60)
            let cap = baseline + 60
            let next = min((last.actualDuration ?? baseline) + 5, cap)
            return (suggestion: Suggestion(weight: nil, reps: nil, durationSec: next, touched: ["hold-duration"]), updatedRecord: rec)
        }
    }

    // Stall evaluation on finished session (BR-012..BR-016). Caller passes the Current
    // session's performed sets for E and the immediate previous performed session's
    // working weight (nil if there was none).
    public static func onSessionFinished(
        record: ProgressionRecord,
        currentSessionSets: [ReferenceSessionSet],
        previousWorkingWeight: Double?,
        metric: ExerciseMetric,
        exerciseName: String
    ) -> (shouldBanner: Bool, bannerCopy: String?, updatedRecord: ProgressionRecord) {
        let performedNow = currentSessionSets.filter { $0.status != .dropped }
        guard !performedNow.isEmpty else { return (shouldBanner: false, bannerCopy: nil, record) }       // not performed → no touch

        var rec = record
        let currentW = performedNow.max(by: { $0.setOrdinal < $1.setOrdinal })?.actualWeight

        // Weight change resets chain — even mid-stall.
        if let prev = previousWorkingWeight, let currentW, prev != currentW {
            rec.stallCount = 0
            return (shouldBanner: false, bannerCopy: nil, rec)
        }

        if clean(sets: performedNow, metric: metric) {
            rec.stallCount = 0
            return (shouldBanner: false, bannerCopy: nil, rec)
        }

        let failedMaxActual = failedMax(sets: performedNow, metric: metric)
        let targetP = (metric == .reps ? performedNow.first?.plannedReps : performedNow.first?.plannedDuration)
        if let F = failedMaxActual, let P = targetP, F < P {
            rec.stallCount += 1
        }
        // else (completed shortfall with no fails) → unchanged per BR-012(d).

        if !rec.stallMuted && rec.stallCount == rec.nextBannerAt {
            let copy = "Looks stalled on \(exerciseName) — \(rec.stallCount) sessions short of target."
            return (shouldBanner: true, bannerCopy: copy, rec)
        }
        return (shouldBanner: false, bannerCopy: nil, rec)
    }

    // Stall-choice application. Caller passes the CURRENT working weight the session
    // materialized at (for Deload snapshotting).
    public static func applyStallChoice(
        _ action: StallAction,
        record: ProgressionRecord,
        currentWeight: Double?,
        currentReps: Int?,
        currentDurationSec: Int?
    ) -> ProgressionRecord {
        var rec = record
        switch action {
        case .deload:
            rec.deloadPending = true
            rec.stalledWeight = currentWeight
            rec.stalledReps = currentReps
            rec.stalledDurationSec = currentDurationSec
        case .hold:
            rec.nextBannerAt = rec.stallCount + 2
        case .ignore:
            rec.stallMuted = true
        }
        return rec
    }

    // Editor touch: resets chain per BR-017.
    public static func resetChainOnEdit(record: ProgressionRecord) -> ProgressionRecord {
        var rec = record
        rec.stallCount = 0
        rec.stallMuted = false
        rec.nextBannerAt = 3
        rec.deloadPending = false
        rec.stalledWeight = nil
        rec.stalledReps = nil
        rec.stalledDurationSec = nil
        return rec
    }
}
