// contractId: SC-prs @1.0.0
// §3a model + seam-1 value types. Canonical post-0009 shape. Additive-only;
// SC-foundation's INV-2 (updatedAt bump) / INV-3 (tombstone) / INV-4 (additive-
// only) hold on every row.

import Foundation

public enum PRKind: String, Codable, CaseIterable, Sendable {
    case max1rm      = "max_1rm"
    case maxVolume   = "max_volume"
    case maxReps     = "max_reps"
    case maxDuration = "max_duration"

    /// BR-005 precedence (0 = highest). Explicit so enum declaration order
    /// is never load-bearing.
    public var precedenceRank: Int {
        switch self {
        case .max1rm:      return 0
        case .maxVolume:   return 1
        case .maxReps:     return 2
        case .maxDuration: return 3
        }
    }
}

public struct PersonalRecord: Codable, Equatable, Sendable {
    public var id: String
    public var exerciseId: String
    public var sessionId: String    // session where achieved; '' sentinel only via legacy 0001→0009 backfill
    public var setId: String?
    public var kind: PRKind
    public var value: Double        // unit per kind (§3b); unrounded
    public var achievedAt: String   // = holding set's completedAt
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?

    public init(id: String, exerciseId: String, sessionId: String, setId: String?, kind: PRKind, value: Double, achievedAt: String, createdAt: String, updatedAt: String, deletedAt: String? = nil) {
        self.id = id
        self.exerciseId = exerciseId
        self.sessionId = sessionId
        self.setId = setId
        self.kind = kind
        self.value = value
        self.achievedAt = achievedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Exercise metric at the seam: reps-metric (weight×reps) vs duration-metric.
/// Sized to what the PR engine gates on (BR-004); deliberately independent of
/// SC-foundation's body-metric `MetricKind`.
public enum SeamMetric: String, Codable, Sendable { case reps, duration }

/// SC-workout-logging §2a set lifecycle at the seam, re-declared locally —
/// the same pattern MooreWorkout/Models.swift uses ("so the module has no
/// module dependency") — raw values are the 0001 SQL CHECK vocabulary, so the
/// DAO maps rows verbatim.
public enum SetStatus: String, Codable, Sendable, CaseIterable {
    case planned, completed, failed, dropped
}

/// SC-warmup/SC-foundation INV-6 set classification; nil coalesces to `.work`.
public enum SetClass: String, Codable, Sendable {
    case warmup, work
}

/// Seam-1 input — minimal CompletedSet view consumed by PREngine. Carries
/// `exerciseDefaultMetric` so max_duration gating needs no DB round-trip.
public struct ReferenceSessionSet: Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var exerciseId: String
    public var status: SetStatus
    public var setClass: SetClass?      // nil coalesces to .work (INV-6)
    public var actualWeight: Double?
    public var actualReps: Int?
    public var actualDuration: Int?
    public var completedAt: String?
    public var exerciseDefaultMetric: SeamMetric?

    public init(id: String, sessionId: String, exerciseId: String, status: SetStatus, setClass: SetClass? = nil, actualWeight: Double? = nil, actualReps: Int? = nil, actualDuration: Int? = nil, completedAt: String? = nil, exerciseDefaultMetric: SeamMetric? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.exerciseId = exerciseId
        self.status = status
        self.setClass = setClass
        self.actualWeight = actualWeight
        self.actualReps = actualReps
        self.actualDuration = actualDuration
        self.completedAt = completedAt
        self.exerciseDefaultMetric = exerciseDefaultMetric
    }
}

/// Cue descriptor for `cue.pr.achieved`. Callers dispatch; the engine only
/// describes. Haptic class is #10's `celebration`; toast copy is §6-keyed.
public struct PRFiredCue: Equatable, Sendable {
    public var cueId: String
    public var hapticClass: String
    public var headlineKind: PRKind
    public var value: Double
    public var exerciseId: String

    public init(headlineKind: PRKind, value: Double, exerciseId: String) {
        self.cueId = "cue.pr.achieved"
        self.hapticClass = "celebration"
        self.headlineKind = headlineKind
        self.value = value
        self.exerciseId = exerciseId
    }
}

/// What `processNewSet`/`writeFromSet` return. Live path only ever contains
/// beaten kinds (BR-002: no baseline row ⇒ nothing written, nothing fired) —
/// `written == beaten`. Exactly one cue descriptor comes back, headline per
/// BR-005 precedence, when at least one kind beat its baseline.
public struct PRWrite: Equatable, Sendable {
    public var written: [PRKind]
    public var beaten: [PRKind]
    public var values: [PRKind: Double]
    public var fired: PRFiredCue?

    public init(written: [PRKind], beaten: [PRKind], values: [PRKind: Double], fired: PRFiredCue?) {
        self.written = written
        self.beaten = beaten
        self.values = values
        self.fired = fired
    }
}

/// History PR-badge row (#36 groundwork for #37, SC-prs §9 feeds #27): the
/// live PR count of one session, dated by the session's start day (UTC).
/// `personal_record_session_idx` carries the probe.
public struct SessionPRBadge: Equatable, Sendable {
    public var sessionId: String
    /// `YYYY-MM-DD` — substr of `workout_session.startedAt` (ISO-8601 UTC).
    public var day: String
    public var prCount: Int

    public init(sessionId: String, day: String, prCount: Int) {
        self.sessionId = sessionId
        self.day = day
        self.prCount = prCount
    }
}
