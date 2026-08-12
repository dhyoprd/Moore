// contractId: SC-prs @1.0.0
// §4–§5 two-path engine, per binding ticket ruling:
//
//   processNewSet  — LIVE path, fired on set completion. Writes/cues ONLY when
//                    a baseline row for (exerciseId, kind) already exists AND the
//                    new value strictly exceeds it. Never seeds. (BR-002)
//   rederive       — MAINTENANCE path, fired on import / edit / delete. Seeds
//                    baseline rows where none exist; rewrites holders whose
//                    bookmark moved; tombstones kinds that no longer qualify.
//                    Never cues. (BR-007/BR-008/BR-009)
//
// Closed-form, pure, byte-identical across platforms (§9).

import Foundation

public enum PREngine {

    /// Epley 1RM: weight × (1 + reps/30). Stored unrounded (BR-003).
    public static func epley1RM(weight: Double, reps: Int) -> Double {
        weight * (1.0 + Double(reps) / 30.0)
    }

    /// BR-001 candidate gate: `status = completed` AND `coalesce(setClass,'work') = 'work'`.
    /// Failed/dropped never qualify; warmup rows are invisible.
    public static func isEligibleWorkSet(_ s: ReferenceSessionSet) -> Bool {
        guard s.status == .completed else { return false }
        return (s.setClass ?? .work) == .work
    }

    /// BR-004 per-kind computed value, nil when BR-004's gate excludes the set.
    public static func value(of kind: PRKind, on s: ReferenceSessionSet) -> Double? {
        guard isEligibleWorkSet(s) else { return nil }
        switch kind {
        case .max1rm:
            guard let w = s.actualWeight, w > 0, let r = s.actualReps, r > 0 else { return nil }
            return epley1RM(weight: w, reps: r)
        case .maxVolume:
            guard let w = s.actualWeight, w > 0, let r = s.actualReps, r > 0 else { return nil }
            return w * Double(r)
        case .maxReps:
            guard let r = s.actualReps, r > 0 else { return nil }
            return Double(r)
        case .maxDuration:
            guard s.exerciseDefaultMetric == .duration else { return nil }
            guard let d = s.actualDuration, d > 0 else { return nil }
            return Double(d)
        }
    }

    /// LIVE path (BR-002/BR-003/BR-005/BR-006). First-ever set for an exercise
    /// NEVER fires: with no pre-existing baseline row there is nothing to beat,
    /// and this function writes nothing. Baselines are created exclusively by
    /// `rederive` (import / edit / delete) or by prior `processNewSet` writes.
    ///
    /// When the candidate beats multiple kinds, every beaten kind's row upserts
    /// (INV-PR2) but exactly one cue descriptor comes back — headline per BR-005
    /// precedence. Strict exceed only; equality writes nothing (BR-003).
    public static func processNewSet(
        set: ReferenceSessionSet,
        baselines: [PRKind: PersonalRecord]
    ) -> PRWrite? {
        guard isEligibleWorkSet(set) else { return nil }

        var beaten: [PRKind] = []
        var values: [PRKind: Double] = [:]
        for kind in PRKind.allCases {
            guard let baseline = baselines[kind] else { continue }   // no row → nothing to beat (BR-002)
            guard let v = value(of: kind, on: set) else { continue } // BR-001/BR-004 gate
            guard v > baseline.value else { continue }               // BR-003 strict exceed
            beaten.append(kind)
            values[kind] = v
        }
        guard !beaten.isEmpty else { return nil }

        beaten.sort { $0.precedenceRank < $1.precedenceRank }
        let fired = PRFiredCue(headlineKind: beaten[0], value: values[beaten[0]] ?? 0, exerciseId: set.exerciseId)
        return PRWrite(written: beaten, beaten: beaten, values: values, fired: fired)
    }

    /// MAINTENANCE path (BR-007/BR-008/BR-009). Recompute the per-kind bookmark
    /// over the exercise's full live history (INV-PR4). Holder per kind = max
    /// value; ties keep earliest completedAt. Silent by construction: returns
    /// bookmark descriptors only, never a cue (BR-009).
    public static func rederive(exerciseHistory: [ReferenceSessionSet])
        -> [PRKind: (value: Double, setId: String?, sessionId: String?, achievedAt: String?)] {
        let work = exerciseHistory.filter { isEligibleWorkSet($0) }
        guard !work.isEmpty else { return [:] }

        var out: [PRKind: (value: Double, setId: String?, sessionId: String?, achievedAt: String?)] = [:]
        for kind in PRKind.allCases {
            var holder: ReferenceSessionSet? = nil
            var best: Double? = nil
            for s in work {
                guard let v = value(of: kind, on: s) else { continue }
                if let b = best {
                    if v > b || (v == b && earlierWins(s, holder)) { best = v; holder = s }
                } else {
                    best = v; holder = s
                }
            }
            if let h = holder, let b = best {
                out[kind] = (value: b, setId: h.id, sessionId: h.sessionId, achievedAt: h.completedAt)
            }
        }
        return out
    }

    /// completedAt ordering with id tiebreak (ISO-8601 UTC text).
    private static func earlierWins(_ a: ReferenceSessionSet, _ b: ReferenceSessionSet?) -> Bool {
        guard let b else { return true }
        let at = a.completedAt ?? ""
        let bt = b.completedAt ?? ""
        if at != bt { return at < bt }
        return a.id < b.id
    }
}
