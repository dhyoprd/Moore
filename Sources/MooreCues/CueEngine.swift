// contractId: SC-cues @1.0.0
// The cue engine (§4/§5) — pure evaluation: one event in, zero or one
// dispatch out, with the BR-014 gate order: backgrounded (BR-005) → morph
// (BR-006) → first-touch (BR-007) → per-set budget (BR-008) → dedupe
// (BR-012) → dispatch. Foundation only. The engine never reads a clock
// (INV-C2): every event carries its instant, and the accumulators it mutates
// live in CueState — in-memory only, never persisted (INV-C1).

import Foundation

/// One cue event presented to the engine. `at` is host-supplied (INV-C2).
public struct CueEvent: Equatable, Sendable {
    public var name: CueName
    public var at: Date
    /// Per-set scope: the budget gate (BR-008) keys on this.
    public var setId: String?
    /// prAchieved only: the SC-prs `PRWrite.beaten` kinds. Empty/nil ⇒
    /// first-touch suppression (BR-007); headline per BR-008.
    public var beatenKinds: [String]?

    public init(name: CueName, at: Date, setId: String? = nil, beatenKinds: [String]? = nil) {
        self.name = name
        self.at = at
        self.setId = setId
        self.beatenKinds = beatenKinds
    }
}

/// Delivery class of a fired dispatch (BR-005).
public enum CueDelivery: String, Equatable, Sendable {
    /// In-process rendering via the CueSink seam.
    case inProcess
    /// Notification-class delivery — the host's local-notification surface
    /// (iOS UNUserNotificationCenter; Android WorkManager-equivalent, #13)
    /// owns the rendering; only cue.rest.end ever carries it (INV-C6).
    case localNotification
}

/// One fired cue, fully resolved against device context (§3).
public struct CueDispatch: Equatable, Sendable {
    public var cue: CueName
    /// nil = no haptic (BR-002).
    public var haptic: HapticClass?
    /// Silenced ⇒ false (BR-004).
    public var audio: Bool
    /// INV-C3: always present — every cue degrades to visual-only.
    public var visual: String
    /// INV-C5: true only for cue.confirm.destructive (BR-010).
    public var blocking: Bool
    public var delivery: CueDelivery
    /// prAchieved only (BR-008): the highest-precedence beaten kind.
    public var headlineKind: String?

    public init(
        cue: CueName,
        haptic: HapticClass?,
        audio: Bool,
        visual: String,
        blocking: Bool,
        delivery: CueDelivery,
        headlineKind: String?
    ) {
        self.cue = cue
        self.haptic = haptic
        self.audio = audio
        self.visual = visual
        self.blocking = blocking
        self.delivery = delivery
        self.headlineKind = headlineKind
    }
}

/// Outcome of one evaluation, as recorded in the ring buffer (BR-013).
public enum CueOutcome: String, Equatable, Sendable {
    case fired
    case suppressed
    case deduped
}

/// Suppression/dedupe reasons — the first failing gate names it (BR-014).
public enum CueReason {
    public static let backgrounded = "backgrounded"
    public static let morphedToFinish = "morphedToFinish"
    public static let firstTouch = "firstTouch"
    public static let prSubsumes = "prSubsumes"
    public static let dedupe500ms = "dedupe500ms"
    public static let unknownCue = "unknownCue"
}

/// One ring-buffer entry (BR-013): fired AND non-fired outcomes are recorded.
public struct CueLogEntry: Equatable, Sendable {
    public var cue: CueName
    public var at: Date
    public var outcome: CueOutcome
    public var reason: String?

    public init(cue: CueName, at: Date, outcome: CueOutcome, reason: String?) {
        self.cue = cue
        self.at = at
        self.outcome = outcome
        self.reason = reason
    }
}

/// §2a accumulators. Reference type so `CueEngine.evaluate(_:state:)` keeps
/// its pure signature; the engine is the sole mutator except the host's
/// `context` writes and `resolveConfirmation()` (§2b exit).
public final class CueState: @unchecked Sendable {
    /// INV-C1: FIFO ring capacity.
    public static let ringCapacity = 64
    /// BR-012: same cue strictly inside this window collapses.
    public static let dedupeWindowSec: TimeInterval = 0.5
    /// BR-005 host scheduling: re-foreground within this span of expiry
    /// favors the in-process cue over the notification.
    public static let backgroundedNotificationGraceSec: TimeInterval = 10

    private let lock = NSLock()
    private var storedContext: DeviceContext
    private var lastFiredAt: [CueName: Date] = [:]
    private var prFiredSetIds: Set<String> = []
    private var storedMorphLatch = false
    private var storedPendingConfirmation = false
    private var storedLog: [CueLogEntry] = []

    public init(context: DeviceContext = DeviceContext()) {
        self.storedContext = context
    }

    // MARK: Host surface

    /// Host lifecycle feeds this; the engine reads it per evaluation.
    public var context: DeviceContext {
        get { lock.lock(); defer { lock.unlock() }; return storedContext }
        set { lock.lock(); storedContext = newValue; lock.unlock() }
    }

    /// §2b latch: a finish morph has consumed the overlay and no new set has
    /// unlatched it (SC-rest INV-T6 mirrored at the cue layer).
    public var overlayMorphedToFinish: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedMorphLatch
    }

    /// §2b confirm machine: a blocking confirm is on screen (BR-010).
    public var pendingConfirmation: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedPendingConfirmation
    }

    /// The ring buffer, oldest → newest (BR-013). Summary/diagnostics read it.
    public var log: [CueLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return storedLog
    }

    /// §2b exit: explicit acceptance (the destructive write may now execute)
    /// or explicit rejection (it must not). No other event resolves a confirm.
    public func resolveConfirmation() {
        lock.lock()
        storedPendingConfirmation = false
        lock.unlock()
    }

    // MARK: Engine-only mutation (single critical section per evaluate)

    /// Run `body` holding the state lock — CueEngine evaluates atomically.
    public func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    fileprivate func recordFire(_ event: CueEvent, reason: String?) {
        storedLog.append(CueLogEntry(cue: event.name, at: event.at, outcome: .fired, reason: reason))
        evictIfNeeded()
        lastFiredAt[event.name] = event.at
    }

    fileprivate func recordSuppressed(_ event: CueEvent, reason: String) {
        storedLog.append(CueLogEntry(cue: event.name, at: event.at, outcome: .suppressed, reason: reason))
        evictIfNeeded()
    }

    fileprivate func recordDeduped(_ event: CueEvent) {
        storedLog.append(CueLogEntry(cue: event.name, at: event.at, outcome: .deduped, reason: CueReason.dedupe500ms))
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while storedLog.count > Self.ringCapacity {
            storedLog.removeFirst()
        }
    }

    fileprivate func lastFired(at name: CueName) -> Date? { lastFiredAt[name] }
    fileprivate func currentContext() -> DeviceContext { storedContext }
    fileprivate func morphLatch() -> Bool { storedMorphLatch }
    fileprivate func setMorphLatch(_ value: Bool) { storedMorphLatch = value }
    fileprivate func prFired(contains setId: String) -> Bool { prFiredSetIds.contains(setId) }
    fileprivate func markPrFired(setId: String) { prFiredSetIds.insert(setId) }
    fileprivate func setPendingConfirmation(_ value: Bool) { storedPendingConfirmation = value }
}

/// The pure engine. Deterministic in (event, state); commits the §2a side
/// effects; never reads a clock (INV-C2).
public enum CueEngine {
    /// One evaluation (BR-014 gate order). Returns zero or one dispatch.
    public static func evaluate(_ event: CueEvent, state: CueState) -> [CueDispatch] {
        state.withLock {
            let channels = event.name.channels
            let context = state.currentContext()

            // Gate 1 — BR-005 (INV-C6): only cue.rest.end reaches a
            // backgrounded/locked device; every other cue merely confirms
            // what the user is already doing.
            if context.appState == .backgroundedOrLocked && event.name != .restEnd {
                state.recordSuppressed(event, reason: CueReason.backgrounded)
                return []
            }

            // Gate 2 — BR-006: rest-end fires only while the overlay is in
            // the `rest` state. After a finish morph the morph IS the cue;
            // the latch clears only on a fired set log (INV-T6 unlatch).
            if event.name == .restEnd && state.morphLatch() {
                state.recordSuppressed(event, reason: CueReason.morphedToFinish)
                return []
            }

            // Gate 3 — BR-007: first-touch PR suppression. No beaten kinds
            // (no baseline existed to beat, SC-prs BR-002) ⇒ no cue. Unknown
            // kind strings are ignored; if no known kind remains, firstTouch.
            var headlineKind: String?
            if event.name == .prAchieved {
                headlineKind = PRKindPrecedence.headline(of: event.beatenKinds ?? [])
                if headlineKind == nil {
                    state.recordSuppressed(event, reason: CueReason.firstTouch)
                    return []
                }
            }

            // Gate 4 — BR-008 (INV-C4): the celebration subsumes the tick.
            // A fired prAchieved recorded its setId; the completion tick for
            // that same set never fires a second haptic.
            if event.name == .setCompleted, let setId = event.setId, state.prFired(contains: setId) {
                state.recordSuppressed(event, reason: CueReason.prSubsumes)
                return []
            }

            // Gate 5 — BR-012: same cue strictly inside 500ms of its last
            // FIRED dispatch collapses. The boundary (exactly 500ms) fires;
            // suppressed/deduped evaluations never advance the window.
            if let last = state.lastFired(at: event.name),
               event.at.timeIntervalSince(last) < CueState.dedupeWindowSec {
                state.recordDeduped(event)
                return []
            }

            // Dispatch — BR-002/BR-004 channel resolution, BR-005 delivery.
            let audio = channels.audio && !context.silenced
            let delivery: CueDelivery =
                (event.name == .restEnd && context.appState == .backgroundedOrLocked)
                ? .localNotification
                : .inProcess
            let dispatch = CueDispatch(
                cue: event.name,
                haptic: channels.haptic,
                audio: audio,
                visual: channels.visual,
                blocking: channels.blocking,
                delivery: delivery,
                headlineKind: headlineKind
            )

            // Commit side effects (§2a). Fired outcomes only.
            state.recordFire(event, reason: nil)
            switch event.name {
            case .finishMorph:
                state.setMorphLatch(true)
            case .setCompleted, .setFailed:
                // SC-rest INV-T6: a new set log unlatches the overlay to
                // `rest` — only the new run's own terminal flag decides
                // whether ITS expiry morphs.
                state.setMorphLatch(false)
            case .prAchieved:
                if let setId = event.setId {
                    state.markPrFired(setId: setId)
                }
            case .confirmDestructive:
                state.setPendingConfirmation(true)
            case .restEnd, .setDropped, .prSummary:
                break
            }
            return [dispatch]
        }
    }
}
