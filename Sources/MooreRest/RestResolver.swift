// contractId: SC-rest @1.0.0
// BR-001 four-level hierarchy lookup. Pure value type, no GRDB, no platform
// imports — the four levels arrive as inputs so resolution never reaches into
// the database mid-session. Clamping to [0, 600]s happens here (INV-S3), so
// the caller can hand it raw storage values.

import Foundation

/// Which hierarchy level supplied the duration (observability only; never
/// persisted — INV-T2).
public enum RestSource: String, Codable, Equatable, Sendable {
    case perSet
    case perExercise
    case perRoutine
    case globalCompound
    case globalIsolation
}

/// The result of a BR-001 walk: the clamped duration plus where it came from.
public struct RestResolution: Codable, Equatable, Sendable {
    public var durationSec: Int
    public var source: RestSource

    public init(durationSec: Int, source: RestSource) {
        self.durationSec = durationSec
        self.source = source
    }
}

public enum RestResolver {
    /// BR-001: walk per-set → per-exercise → per-routine → global, first
    /// non-null wins. The global default is bucketed by exercise category —
    /// compound ⇒ `defaultRestCompoundSec`, everything else (isolation AND all
    /// duration-metric exercises, #9) ⇒ `defaultRestIsolationSec`. The winner
    /// is clamped to [0, 600]s (INV-S3). Total because settings are guaranteed
    /// seeded (INV-S2).
    public static func resolve(
        perSetSec: Int?,
        perExerciseSec: Int?,
        perRoutineSec: Int?,
        categoryIsCompound: Bool,
        settings: RestSettings
    ) -> RestResolution {
        if let perSetSec {
            return clamped(perSetSec, .perSet)
        }
        if let perExerciseSec {
            return clamped(perExerciseSec, .perExercise)
        }
        if let perRoutineSec {
            return clamped(perRoutineSec, .perRoutine)
        }
        return categoryIsCompound
            ? clamped(settings.defaultRestCompoundSec, .globalCompound)
            : clamped(settings.defaultRestIsolationSec, .globalIsolation)
    }

    private static func clamped(_ durationSec: Int, _ source: RestSource) -> RestResolution {
        let clamped = min(max(durationSec, RestCycle.minDurationSec), RestCycle.maxDurationSec)
        return RestResolution(durationSec: clamped, source: source)
    }
}
