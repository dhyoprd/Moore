// contractId: SC-rest @1.0.0
// The abstract cue channel (#10 taxonomy, §5). This module ONLY defines the
// surface: code dispatches `CueEvent`s into a `CueDispatching`; what happens
// next (haptic alert pattern + one short tone + visual flip in-process;
// local-notification-class delivery when backgrounded/locked; silenced-device
// degradation per #10's five-point contract) is #29's platform seam.
//
// `InMemoryCueDispatcher` is the seam-3 test double: it records every event so
// fixtures can assert exactly-which-cues-fired without any platform haptics.

import Foundation

public protocol CueDispatching: Sendable {
    func dispatch(_ cue: CueEvent)
}

/// Seam-3 spy: records dispatched cues in order. Not for production — the
/// concrete iOS implementation lands in #29.
public final class InMemoryCueDispatcher: CueDispatching, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CueEvent] = []

    public init() {}

    public func dispatch(_ cue: CueEvent) {
        lock.lock()
        recorded.append(cue)
        lock.unlock()
    }

    /// All cues dispatched so far, in dispatch order.
    public var events: [CueEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    public func reset() {
        lock.lock()
        recorded.removeAll()
        lock.unlock()
    }
}
