// contractId: SC-cues @1.0.0
// The cue vocabulary (§3) — eight cue IDs, four haptic classes, the
// cue→channel mapping table (#10 taxonomy, verbatim), device context, and the
// PR-kind precedence helper (BR-008 headline rule). Port-wide vocabulary:
// code cites "cue.rest.end", never a local name (#10 downstream ruling).
// Foundation only — no UIKit, no CoreHaptics (platform delivery sits behind
// the CueSink seam in CueDispatcher.swift).

import Foundation

/// §3 CueName — the eight cues of v1, addressed by ID. Raw values are the
/// port-wide cue IDs. INV-C7: unknown/forward-compat ids never construct a
/// case (`init(rawValue:)` fails) and are suppressed upstream, never a crash.
public enum CueName: String, CaseIterable, Codable, Sendable {
    case restEnd = "cue.rest.end"
    case setCompleted = "cue.set.completed"
    case setFailed = "cue.set.failed"
    case setDropped = "cue.set.dropped"
    case prAchieved = "cue.pr.achieved"
    case prSummary = "cue.pr.summary"
    case finishMorph = "cue.finish.morph"
    case confirmDestructive = "cue.confirm.destructive"
}

/// §3b HapticClass — the four haptic characters (#10, verbatim).
public enum HapticClass: String, CaseIterable, Codable, Sendable {
    /// Single light tick — "logged".
    case success
    /// Single medium tap — "attention warranted, nothing wrong".
    case nudge
    /// Repeated urgent pattern — "return to work now".
    case alert
    /// Distinct multi-stage pattern — "achievement"; exactly one cue per set.
    case celebration
}

/// Foreground axis of DeviceContext. Backgrounded and locked are one bucket:
/// the cue contract cares only whether in-process surfaces are reachable.
public enum ForegroundState: String, Codable, Sendable {
    case foreground
    case backgroundedOrLocked
}

/// §3 DeviceContext — host-supplied; the engine never reads lifecycle itself.
public struct DeviceContext: Equatable, Sendable {
    public var appState: ForegroundState
    public var silenced: Bool

    public init(appState: ForegroundState = .foreground, silenced: Bool = false) {
        self.appState = appState
        self.silenced = silenced
    }
}

/// §3(a) one row of the cue→channel mapping table.
public struct CueChannelSet: Equatable, Sendable {
    /// nil = no haptic (BR-002: dropped / pr.summary / finish.morph / confirm).
    public var haptic: HapticClass?
    /// Only `cue.rest.end` carries audio; silenced devices drop it (BR-004).
    public var audio: Bool
    /// INV-C3: every cue degrades to this visual element at minimum.
    public var visual: String
    /// Silenced = audio-only kill; haptic + visual still fire (#10 table).
    public var firesSilenced: Bool
    /// INV-C6: true for exactly one cue — `cue.rest.end` (BR-005).
    public var firesBackgroundedOrLocked: Bool
    /// INV-C5: true for exactly one cue — `cue.confirm.destructive` (BR-010).
    public var blocking: Bool

    public init(
        haptic: HapticClass?,
        audio: Bool,
        visual: String,
        firesSilenced: Bool,
        firesBackgroundedOrLocked: Bool,
        blocking: Bool
    ) {
        self.haptic = haptic
        self.audio = audio
        self.visual = visual
        self.firesSilenced = firesSilenced
        self.firesBackgroundedOrLocked = firesBackgroundedOrLocked
        self.blocking = blocking
    }
}

extension CueName {
    /// The §3(a) table, in code. One row per cue; the JS mirror and the
    /// fixtures assert byte-parity against this table (VerifyCues.mjs).
    public var channels: CueChannelSet {
        switch self {
        case .restEnd:
            return CueChannelSet(
                haptic: .alert, audio: true, visual: "rest.over",
                firesSilenced: true, firesBackgroundedOrLocked: true, blocking: false)
        case .setCompleted:
            return CueChannelSet(
                haptic: .success, audio: false, visual: "set.checkFill",
                firesSilenced: true, firesBackgroundedOrLocked: false, blocking: false)
        case .setFailed:
            return CueChannelSet(
                haptic: .nudge, audio: false, visual: "set.failDelta",
                firesSilenced: true, firesBackgroundedOrLocked: false, blocking: false)
        case .setDropped:
            // BR-009: a drop has NO haptic — the undo toolbar is the cue.
            return CueChannelSet(
                haptic: nil, audio: false, visual: "set.dropUndo",
                firesSilenced: true, firesBackgroundedOrLocked: false, blocking: false)
        case .prAchieved:
            return CueChannelSet(
                haptic: .celebration, audio: false, visual: "pr.toast",
                firesSilenced: true, firesBackgroundedOrLocked: false, blocking: false)
        case .prSummary:
            return CueChannelSet(
                haptic: nil, audio: false, visual: "pr.cards",
                firesSilenced: true, firesBackgroundedOrLocked: false, blocking: false)
        case .finishMorph:
            return CueChannelSet(
                haptic: nil, audio: false, visual: "finish.morph",
                firesSilenced: true, firesBackgroundedOrLocked: false, blocking: false)
        case .confirmDestructive:
            // INV-C5: the only blocking cue in v1 (BR-010). No haptic: a buzz
            // preceding a decision is a demand for attention, and the witness
            // budget forbids it (§8).
            return CueChannelSet(
                haptic: nil, audio: false, visual: "confirm.modal",
                firesSilenced: true, firesBackgroundedOrLocked: false, blocking: true)
        }
    }
}

/// BR-008 headline rule — one cue per set, precedence
/// max_1rm > max_volume > max_reps > max_duration (SC-prs BR-005 re-stated as
/// the cue-layer headline selection). Kind strings are SC-prs's canonical
/// raw values (INV-PR1 closed vocabulary); unknown kinds are ignored (BR-007).
public enum PRKindPrecedence {
    /// Highest precedence first.
    public static let order: [String] = ["max_1rm", "max_volume", "max_reps", "max_duration"]

    /// 0 = highest precedence; nil for unknown kinds.
    public static func rank(of kind: String) -> Int? {
        order.firstIndex(of: kind)
    }

    /// The headline kind among the beaten kinds, or nil when no known kind
    /// remains (empty / all-unknown ⇒ first-touch suppression, BR-007).
    public static func headline(of beatenKinds: [String]) -> String? {
        var best: String?
        var bestRank = Int.max
        for kind in beatenKinds {
            guard let rank = rank(of: kind) else { continue }
            if rank < bestRank {
                bestRank = rank
                best = kind
            }
        }
        return best
    }
}
