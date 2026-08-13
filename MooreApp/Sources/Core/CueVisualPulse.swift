// Ticket #40 — the visual pulse surface (SC-cues@1.0.0 INV-C3). Every fired
// dispatch carries a visual element; the platform cue sink publishes each
// rendered element here and overlays bind the stream for emphasis (the
// rest-over alert pulse today; future surfaces bind the same seam). Cue
// DECISIONS never touch this type — the engine's BR-014 gates run first and
// only fired dispatches reach the sink that records here.
//
// Foundation-only (@Observable, no SwiftUI) so it parses/verifies off-Mac;
// SwiftUI views observe it via AppState. Main-thread only: the platform sink
// hops to main before recording (the render edge is the platform's surface).

import Foundation
import Observation
import MooreCues

@Observable
public final class CueVisualPulse {

    /// One rendered visual element, totally ordered by `id`.
    public struct Pulse: Equatable, Sendable {
        /// Monotonic render counter — views key animations on this.
        public let id: UInt64
        /// The §3(a) visual element id, verbatim ("rest.over", "set.checkFill",
        /// "set.failDelta", "set.dropUndo", "pr.toast", "pr.cards",
        /// "finish.morph", "confirm.modal").
        public let element: String
        /// The cue that rendered it.
        public let cue: CueName
    }

    /// The most recently rendered visual element (nil before the first cue).
    public private(set) var latest: Pulse?

    private var counter: UInt64 = 0

    public init() {}

    /// Record one rendered element. Main-thread only (the platform sink hops
    /// before calling; @Observable mutation must stay on one thread).
    public func record(element: String, cue: CueName) {
        counter &+= 1
        latest = Pulse(id: counter, element: element, cue: cue)
    }
}
