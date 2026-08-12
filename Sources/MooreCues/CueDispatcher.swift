// contractId: SC-cues @1.0.0 — extends SC-rest@1.0.0 §5 (EXTEND, don't
// duplicate: the CueDispatching protocol and the InMemoryCueDispatcher spy
// stay in MooreRest; this file supplies the concrete production dispatcher
// that SC-rest BR-008 named "#29's platform seam").
//
// No UIKit / CoreHaptics import: platform delivery sits behind the CueSink
// protocol seam. The iOS host supplies a generator-backed sink; the Android
// port supplies VibrationEffect + the WorkManager-equivalent notification
// surface for `delivery == .localNotification` (#13).

import Foundation
import MooreRest

/// Platform delivery seam (§5). One fired dispatch fans out to at most three
/// channel calls: haptic (when present), tone (when audible), visual (always
/// — INV-C3). Blocking dispatches present their modal via the visual call;
/// the write gate itself is the host's contract (BR-010).
public protocol CueSink: Sendable {
    func playHaptic(_ hapticClass: HapticClass)
    func playTone()
    func presentVisual(_ element: String, forCue cue: CueName)
}

/// Seam-3 spy for the sink side: records every rendered channel call so fire
/// order, silenced-mode behavior, and delivery degradation are assertable
/// without platform haptics. SC-rest's InMemoryCueDispatcher remains the
/// rest-channel spy; this one records what the dispatcher DID with the cue.
public final class RecordingCueSink: CueSink, @unchecked Sendable {
    public enum Call: Equatable, Sendable {
        case haptic(HapticClass)
        case tone
        case visual(String, CueName)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    public init() {}

    public func playHaptic(_ hapticClass: HapticClass) {
        lock.lock(); recorded.append(.haptic(hapticClass)); lock.unlock()
    }

    public func playTone() {
        lock.lock(); recorded.append(.tone); lock.unlock()
    }

    public func presentVisual(_ element: String, forCue cue: CueName) {
        lock.lock(); recorded.append(.visual(element, cue)); lock.unlock()
    }

    /// All rendered calls, in render order.
    public var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    public func reset() {
        lock.lock(); recorded.removeAll(); lock.unlock()
    }
}

/// The concrete cue dispatcher. Conforms to SC-rest's CueDispatching so
/// `RestCycle.dispatch(_:into:)` accepts it directly; also accepts full-
/// taxonomy CueEvents from the set-lifecycle / PR / confirm callers.
public final class CueDispatcher: CueDispatching, @unchecked Sendable {
    private let state: CueState
    private let sink: CueSink
    /// The ONLY clock read in this module, at the platform edge (the engine
    /// itself never reads time — INV-C2); injectable for tests.
    private let clock: @Sendable () -> Date

    public init(sink: CueSink, state: CueState = CueState(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.sink = sink
        self.state = state
        self.clock = clock
    }

    /// The device context the engine gates on. Host lifecycle writes it.
    public var context: DeviceContext {
        get { state.context }
        set { state.context = newValue }
    }

    /// The ring buffer (BR-013) — Summary/diagnostics seam.
    public var cueLog: [CueLogEntry] { state.log }

    /// §2b exit — explicit acceptance/rejection of a pending confirm.
    public func resolveConfirmation() { state.resolveConfirmation() }

    // MARK: SC-rest seam (CueDispatching)

    /// SC-rest's two-case emission (restEnd / finishMorph), bridged into the
    /// full taxonomy at the dispatch instant.
    public func dispatch(_ cue: MooreRest.CueEvent) {
        dispatch(CueEvent(restEvent: cue, at: clock()))
    }

    // MARK: Full-taxonomy entry

    /// Evaluate one event and render every resulting dispatch (zero or one).
    @discardableResult
    public func dispatch(_ event: CueEvent) -> [CueDispatch] {
        let dispatches = CueEngine.evaluate(event, state: state)
        for dispatch in dispatches {
            render(dispatch)
        }
        return dispatches
    }

    /// BR-002 fan-out: haptic (if present) → tone (if audible) → visual
    /// (always). A `localNotification` delivery hands the rendering to the
    /// sink as well — the host's sink decides notification-class rendering
    /// from the dispatch's delivery field; the engine stays platform-free.
    private func render(_ dispatch: CueDispatch) {
        if let haptic = dispatch.haptic {
            sink.playHaptic(haptic)
        }
        if dispatch.audio {
            sink.playTone()
        }
        sink.presentVisual(dispatch.visual, forCue: dispatch.cue)
    }
}

extension CueEvent {
    /// SC-rest bridge: the rest FSM emits MooreRest.CueEvent { restEnd,
    /// finishMorph }; both are members of this contract's taxonomy.
    public init(restEvent: MooreRest.CueEvent, at: Date) {
        switch restEvent {
        case .restEnd:
            self.init(name: .restEnd, at: at)
        case .finishMorph:
            self.init(name: .finishMorph, at: at)
        }
    }
}
