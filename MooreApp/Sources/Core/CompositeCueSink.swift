// Ticket #40 — composite CueSink (SC-cues@1.0.0 §5). Fans every rendered
// channel call out to all sinks in order: the platform renderer (real
// haptic/audio/visual delivery, #40) plus the RecordingCueSink spy, kept live
// at boot so diagnostics still see every rendered channel call exactly as
// before #40.
//
// Architecture rule, restated: cue DECISIONS (BR-014 gate order, morph
// suppression, per-set budget, dedupe, silenced audio kill) stay in CueEngine;
// every sink composed here renders only what the engine fired. The ring buffer
// (BR-013) rides CueState — read it via CueDispatcher.cueLog, independent of
// which sinks render.
//
// Foundation-only (no UIKit) so it parses/verifies off-Mac.

import Foundation
import MooreCues

public struct CompositeCueSink: CueSink, Sendable {
    public let sinks: [any CueSink]

    public init(sinks: [any CueSink]) {
        self.sinks = sinks
    }

    public func playHaptic(_ hapticClass: HapticClass) {
        for sink in sinks { sink.playHaptic(hapticClass) }
    }

    public func playTone() {
        for sink in sinks { sink.playTone() }
    }

    public func presentVisual(_ element: String, forCue cue: CueName) {
        for sink in sinks { sink.presentVisual(element, forCue: cue) }
    }
}
