// contractId: SC-rest @1.0.0
// The rest-cycle state machine (§2a) + parallel overlay morph axis (§2b).
// Pure value type: no GRDB, no platform imports, no wall-clock reads — every
// action carries its instant (`at:`) from #22's caller. Timer state is
// in-memory only (INV-T2); nothing here is ever persisted.

import Foundation

/// One cue emitted into the abstract channel (#10 taxonomy). Concrete iOS
/// delivery (haptic alert + tone + visual; local-notification-class when
/// backgrounded/locked) is #29's seam — this module only emits the event.
public enum CueEvent: Equatable, Sendable {
    /// `cue.rest.end` — haptic `alert` + one short tone + visual rest-over flip.
    case restEnd
    /// `cue.finish.morph` — visual only; the morph is the entire cue (#10).
    case finishMorph
}

/// Actions dispatched into the cycle (§5). `setCompleted`/`setFailed` carry the
/// BR-001-resolved duration for the *newly logged* set (INV-T1).
public enum RestAction: Equatable, Sendable {
    case setCompleted(resolution: RestResolution, allSetsTerminal: Bool, at: Date)
    case setFailed(resolution: RestResolution, allSetsTerminal: Bool, at: Date)
    case setDropped
    case skip(at: Date)
    case adjustSec(delta: Int, at: Date)
    case expireNaturally(at: Date)
    case backgrounded(at: Date)
}

public struct RestCycle: Equatable, Sendable {
    /// §2a rest-cycle states.
    public enum State: Equatable, Sendable {
        case noRest
        case restRunning(durationSec: Int, startedAt: Date, adjustmentSec: Int)
        case restExpired(durationSec: Int, startedAt: Date, adjustmentSec: Int)
    }

    /// §2b parallel overlay surface axis.
    public enum Overlay: Equatable, Sendable {
        case rest
        case finishPanel
    }

    public private(set) var state: State
    public private(set) var overlay: Overlay
    /// §2b latch: set at each set log (the caller knows session-wide terminality).
    /// Consumed when the current run expires or is skipped — the morph decision.
    public private(set) var allSetsTerminal: Bool

    /// Hard clamps for adjustments and resolution (BR-002, INV-S3).
    public static let minDurationSec = 0
    public static let maxDurationSec = 600

    public init() {
        self.state = .noRest
        self.overlay = .rest
        self.allSetsTerminal = false
    }

    /// The surface #22's money screen binds to (§5).
    public var current: State { state }

    // MARK: - Derived timing (always computed, never ticked — BR-007)

    /// Absolute expiry instant of a run.
    public static func expiresAt(durationSec: Int, startedAt: Date, adjustmentSec: Int) -> Date {
        startedAt.addingTimeInterval(TimeInterval(durationSec + adjustmentSec))
    }

    /// Remaining seconds at `now`; ≤ 0 means expired (BR-007 presents as expired).
    public static func remainingSec(durationSec: Int, startedAt: Date, adjustmentSec: Int, now: Date) -> Int {
        Int(expiresAt(durationSec: durationSec, startedAt: startedAt, adjustmentSec: adjustmentSec).timeIntervalSince(now))
    }

    // MARK: - Transitions (§2a/2b matrices)

    /// Apply one action; return the cue to dispatch, or nil when none fires
    /// (INV-T3 fire-once: a morphed or skipped run emits nothing at expiry).
    /// The FSM never touches a dispatcher itself — it *emits* the event and the
    /// caller routes it to `CueDispatching` (`dispatch(_:into:)` below).
    @discardableResult
    public mutating func dispatch(_ action: RestAction) -> CueEvent? {
        switch action {

        case let .setCompleted(resolution, terminal, at),
             let .setFailed(resolution, terminal, at):
            // BR-001/INV-T1: fresh run with the new set's resolved duration.
            // BR-004: restart from restRunning/restExpired discards the old run
            // un-cued and resets adjustment to 0. BR-006/INV-T4: the final set
            // starts rest exactly like every other set; `terminal` only latches
            // the §2b morph decision for when this run later ends. A fresh run
            // always unlatches the overlay to `rest` so only THIS run's terminal
            // flag governs whether ITS expiry morphs — a previous session-phase's
            // finish panel cannot absorb a later run's rest-end cue (#10).
            let clamped = Self.clamp(resolution.durationSec)
            state = .restRunning(durationSec: clamped, startedAt: at, adjustmentSec: 0)
            allSetsTerminal = terminal
            overlay = .rest
            return nil

        case .setDropped:
            // BR-005: a drop never starts rest, and never modifies a run.
            return nil

        case let .skip(at):
            _ = at
            // BR-003: instant cancel/dismiss, no write, no cue from the rest
            // channel. If nothing actionable remains (§2b latch), skipping the
            // final rest morphs to the finish panel — the morph is the cue.
            switch state {
            case .noRest:
                return nil
            case .restRunning, .restExpired:
                if allSetsTerminal {
                    state = .noRest
                    overlay = .finishPanel
                    return .finishMorph
                }
                state = .noRest
                return nil
            }

        case let .adjustSec(delta, at):
            // BR-002: accumulate onto the running timer; clamped; ≤0 remaining
            // is skip-equivalent. Never persisted (INV-T2).
            guard case let .restRunning(durationSec, startedAt, adjustmentSec) = state else {
                return nil // adjusting a non-running timer is a no-op
            }
            let newAdjustment = adjustmentSec + delta
            let remaining = Self.remainingSec(durationSec: durationSec, startedAt: startedAt, adjustmentSec: newAdjustment, now: at)
            if remaining <= 0 {
                // −15 with <15s remaining ⇒ skip (BR-002/BR-003): no cue.
                state = .noRest
                return nil
            }
            // Clamp total span to [0, 600]s via the accumulated adjustment (INV-S3).
            let capped = Self.clampSpan(durationSec: durationSec, adjustmentSec: newAdjustment, startedAt: startedAt, now: at)
            state = .restRunning(durationSec: durationSec, startedAt: startedAt, adjustmentSec: capped)
            return nil

        case let .expireNaturally(at):
            return expire(at: at, reusableAcrossStates: true)

        case let .backgrounded(at):
            // BR-007: recompute from timestamps; identical path to relaunch.
            return expire(at: at, reusableAcrossStates: true)
        }
    }

    // MARK: - Internals

    /// Shared expiry/recompute path for `expireNaturally` and `backgrounded`
    /// (BR-007). Emits `cue.rest.end` at most once per run (INV-T3), gated to
    /// the overlay's `rest` state. A final-set run (§2b latch) morphs instead —
    /// the morph is the entire cue, zero haptic, zero audio (#10).
    private mutating func expire(at now: Date, reusableAcrossStates _: Bool) -> CueEvent? {
        switch state {
        case .noRest:
            return nil
        case .restExpired:
            // Already expired; cue was emitted on first crossing (or the morph
            // already consumed the run). Re-arrival is a no-op (INV-T3).
            return nil
        case let .restRunning(durationSec, startedAt, adjustmentSec):
            let remaining = Self.remainingSec(durationSec: durationSec, startedAt: startedAt, adjustmentSec: adjustmentSec, now: now)
            if remaining > 0 {
                return nil // still running; recompute only, no state change
            }
            if allSetsTerminal {
                // §2b: the expiring final-set rest morphs to the finish panel.
                state = .noRest
                overlay = .finishPanel
                return .finishMorph
            }
            // Ordinary expiry: fire `cue.rest.end` exactly once.
            state = .restExpired(durationSec: durationSec, startedAt: startedAt, adjustmentSec: adjustmentSec)
            return .restEnd
        }
    }

    private static func clamp(_ durationSec: Int) -> Int {
        Swift.min(Swift.max(durationSec, minDurationSec), maxDurationSec)
    }

    /// Cap the effective total span (duration + adjustment) at maxDurationSec by
    /// shrinking the adjustment, never touching the resolved duration itself.
    private static func clampSpan(durationSec: Int, adjustmentSec: Int, startedAt: Date, now: Date) -> Int {
        _ = now
        let total = durationSec + adjustmentSec
        guard total > maxDurationSec else { return adjustmentSec }
        return maxDurationSec - durationSec
    }
}

// MARK: - Cue-channel bridge (§5; abstract channel, concrete delivery in #29)

extension RestCycle {
    /// Apply an action and route any emitted cue into `channel`. This is the
    /// BR-008 seam: one cue per expiry, dispatched into the abstract channel;
    /// the concrete multi-channel fan-out is #29's concern.
    @discardableResult
    public mutating func dispatch<C: CueDispatching>(_ action: RestAction, into channel: C) -> CueEvent? {
        let cue = dispatch(action)
        if let cue {
            channel.dispatch(cue)
        }
        return cue
    }
}
