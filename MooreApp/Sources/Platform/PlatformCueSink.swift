// Ticket #40 — the platform cue renderer (SC-cues@1.0.0 §5 CueSink seam).
//
// Architecture rule, restated: cue DECISIONS stay in CueEngine (BR-014 gate
// order, morph suppression, per-set budget, first-touch, dedupe, silenced
// audio kill) — this file renders EXACTLY what the engine fired, nothing
// more. The four haptic classes (§3b, verbatim character):
//
//   success     — "Single light tick"   → UIImpactFeedbackGenerator(.light)
//   nudge       — "Single medium tap"   → UIImpactFeedbackGenerator(.medium)
//   alert       — "Repeated urgent pattern" → CoreHaptics triple-transient
//                 pattern (UINotificationFeedbackGenerator .warning fallback)
//   celebration — "Distinct multi-stage pattern" → CoreHaptics three-stage
//                 pattern (UINotificationFeedbackGenerator .success fallback)
//
// Audio: one short system tone — reached only by cue.rest.end (BR-002: the
// sole audio-carrying cue). AudioServices system sounds obey the hardware
// ringer switch, so silenced devices get haptic + visual only — BR-004 is
// enforced twice (the engine zeroes `audio` when context.silenced, and the
// OS silences the tone itself).
//
// Visual (INV-C3): every rendered element is published to CueVisualPulse so
// overlays can bind the render stream for emphasis.
//
// Mac-build-only: imports UIKit / CoreHaptics / AudioToolbox.

import UIKit
import CoreHaptics
import AudioToolbox
import MooreCues

final class PlatformCueSink: CueSink, @unchecked Sendable {

    /// "One short tone" (SC-cues §3a, cue.rest.end only). System sound 1057
    /// ("Tink") — discreet, never a boss; obeys the ringer switch (BR-004).
    private static let restEndTone: SystemSoundID = 1057

    private let visualPulse: CueVisualPulse

    // Haptic machinery — created lazily on first render (main thread).
    private let lock = NSLock()
    private var hapticEngine: CHHapticEngine?
    private var hapticsUnavailable = false
    private var lightImpact: UIImpactFeedbackGenerator?
    private var mediumImpact: UIImpactFeedbackGenerator?
    private var notificationFeedback: UINotificationFeedbackGenerator?

    init(visualPulse: CueVisualPulse) {
        self.visualPulse = visualPulse
    }

    // MARK: CueSink

    func playHaptic(_ hapticClass: HapticClass) {
        DispatchQueue.main.async { self.renderHaptic(hapticClass) }
    }

    func playTone() {
        AudioServicesPlaySystemSound(Self.restEndTone)
    }

    func presentVisual(_ element: String, forCue cue: CueName) {
        DispatchQueue.main.async { self.visualPulse.record(element: element, cue: cue) }
    }

    // MARK: Haptic classes (§3b)

    /// Main thread.
    private func renderHaptic(_ hapticClass: HapticClass) {
        switch hapticClass {
        case .success:
            let generator = lightImpact ?? {
                let g = UIImpactFeedbackGenerator(style: .light)
                lightImpact = g
                return g
            }()
            generator.prepare()
            generator.impactOccurred()

        case .nudge:
            let generator = mediumImpact ?? {
                let g = UIImpactFeedbackGenerator(style: .medium)
                mediumImpact = g
                return g
            }()
            generator.prepare()
            generator.impactOccurred()

        case .alert:
            // "Repeated urgent pattern — return to work now": three sharp,
            // evenly spaced transients at full intensity.
            if !playPattern(Self.alertPattern) {
                fallbackGenerator().notificationOccurred(.warning)
            }

        case .celebration:
            // "Distinct multi-stage pattern — achievement": soft opener,
            // rising swell, final accent. Used by exactly one cue per set
            // (the engine's BR-008 budget guarantees it, not this renderer).
            if !playPattern(Self.celebrationPattern) {
                fallbackGenerator().notificationOccurred(.success)
            }
        }
    }

    /// Reached only when the CoreHaptics path failed for this render — the
    /// closest system-pattern equivalents. Main thread.
    private func fallbackGenerator() -> UINotificationFeedbackGenerator {
        let generator = notificationFeedback ?? {
            let g = UINotificationFeedbackGenerator()
            notificationFeedback = g
            return g
        }()
        generator.prepare()
        return generator
    }

    // MARK: CoreHaptics machinery

    /// alert — repeated urgent pattern: three strong transients, 120 ms apart.
    private static var alertPattern: CHHapticPattern {
        get throws {
            func transient(at time: TimeInterval) -> CHHapticEvent {
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
                    ],
                    relativeTime: time
                )
            }
            return try CHHapticPattern(
                events: [transient(at: 0), transient(at: 0.12), transient(at: 0.24)],
                parameters: []
            )
        }
    }

    /// celebration — distinct multi-stage pattern: opener tick, rising swell,
    /// closing accent.
    private static var celebrationPattern: CHHapticPattern {
        get throws {
            try CHHapticPattern(
                events: [
                    // Stage 1 — soft opener tick.
                    CHHapticEvent(
                        eventType: .hapticTransient,
                        parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                        ],
                        relativeTime: 0
                    ),
                    // Stage 2 — rising swell.
                    CHHapticEvent(
                        eventType: .hapticContinuous,
                        parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7),
                        ],
                        relativeTime: 0.10,
                        duration: 0.30
                    ),
                    // Stage 3 — closing accent.
                    CHHapticEvent(
                        eventType: .hapticTransient,
                        parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0),
                        ],
                        relativeTime: 0.45
                    ),
                ],
                parameters: []
            )
        }
    }

    /// Play a pattern through the shared engine; false ⇒ use the generator
    /// fallback. Main thread.
    private func playPattern(_ pattern: CHHapticPattern) -> Bool {
        guard let engine = sharedHapticEngine() else { return false }
        do {
            try engine.start()
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            // Engine stopped / audio-session hiccup: fall back this once.
            return false
        }
    }

    private func sharedHapticEngine() -> CHHapticEngine? {
        lock.lock()
        defer { lock.unlock() }
        if hapticsUnavailable { return nil }
        if let existing = hapticEngine { return existing }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            hapticsUnavailable = true
            return nil
        }
        guard let engine = try? CHHapticEngine() else {
            hapticsUnavailable = true
            return nil
        }
        // The engine may stop itself (e.g. after backgrounding); restart on
        // reset rather than dropping the cue class.
        engine.resetHandler = { [weak engine] in
            try? engine?.start()
        }
        engine.stoppedHandler = { _ in }
        hapticEngine = engine
        return engine
    }
}
