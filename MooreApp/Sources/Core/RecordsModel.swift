// Ticket #36 — personal records + celebrations state. Foundation-only
// (@Observable, no SwiftUI) so it parses/verifies off-Mac; the SwiftUI layer
// in Views/ binds to this surface and stays thin.
//
// Architecture: this model OWNS the PR concern for the app and DRIVES the
// frozen pure engines — it never reimplements them:
//   • PREngine + PersonalRecordDAO (SC-prs@1.0.0): the two-path write model.
//     Live completion (`writeFromSet`) only ever BEATS an existing baseline
//     row and returns the single headline cue descriptor (BR-002/BR-003/
//     BR-005/BR-006); edit/delete corrections re-derive the record book
//     silently (BR-007/BR-008/BR-009).
//   • CueEngine via MooreCues.CueDispatcher (SC-cues@1.0.0): cue.pr.achieved
//     + cue.pr.summary events are evaluated through the BR-014 gate order —
//     the backgrounded gate (BR-005) makes the in-session celebration
//     foreground-only BY CONSTRUCTION, and first-touch suppression (BR-007)
//     lives in the engine, never in this model.
//
// Celebration delivery stays abstract: the dispatcher renders into the
// recording CueSink seam (SC-cues §5) — the platform haptic driver for the
// `celebration` class is #40. The in-session toast below is the cue's visual
// element (`pr.toast`, SC-cues §3a): compact, ≥3s, queued one-at-a-time,
// never blocking the ✓ path (BR-011).

import Foundation
import Observation
import MooreRecords
import MooreCues
import MooreExercises
import MooreSettings

// MARK: - Cue seam

/// The full-taxonomy cue channel this model dispatches into (SC-cues §5).
/// `MooreCues.CueDispatcher` is the concrete seam: it evaluates each event
/// through CueEngine (BR-014 gates) and renders fired dispatches into the
/// abstract CueSink. Declared so RecordsModel stays testable against a spy
/// and never reaches past the seam.
public protocol FullCueDispatching: Sendable {
    /// Evaluate one event; returns the fired dispatches (zero or one).
    @discardableResult
    func dispatch(_ event: CueEvent) -> [CueDispatch]
}

extension CueDispatcher: FullCueDispatching {}

// MARK: - Display value types (render-ready; views never format)

/// One in-session celebration toast — the `pr.toast` visual element
/// (SC-cues §3a): compact, ≥3s, queued one-at-a-time. Copy is SC-prs §6
/// `toast.pr.new`, naming the HEADLINE kind only (BR-005); other beaten
/// kinds surface silently on the Summary.
public struct PRToast: Identifiable, Equatable, Sendable {
    public let id: String
    /// Resolved toast.pr.new copy.
    public let text: String
    /// Canonical raw value of the headline kind (max_1rm / max_volume /
    /// max_reps / max_duration) — styling hooks, never load-bearing.
    public let headlineKindRaw: String

    public init(id: String, text: String, headlineKindRaw: String) {
        self.id = id
        self.text = text
        self.headlineKindRaw = headlineKindRaw
    }
}

/// One Summary-surface PR card — the `pr.cards` visual element (SC-cues §3a),
/// copy SC-prs §6 `summary.pr.card`. Rows arrive precedence-ordered (BR-005)
/// from `PersonalRecordDAO.fetchSessionPRs` (INV-PR5 render-time read).
public struct PRSummaryCard: Identifiable, Equatable, Sendable {
    public let id: String             // personal_record.id
    public let exerciseId: String
    public let exerciseName: String
    /// Canonical kind raw value (INV-PR1).
    public let kindRaw: String
    /// pr.kind.* §6 label.
    public let kindLabel: String
    /// Display-unit-aware value render ({value} slot).
    public let valueText: String
    /// Resolved summary.pr.card copy.
    public let text: String

    public init(id: String, exerciseId: String, exerciseName: String, kindRaw: String, kindLabel: String, valueText: String, text: String) {
        self.id = id
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.kindRaw = kindRaw
        self.kindLabel = kindLabel
        self.valueText = valueText
        self.text = text
    }
}

// MARK: - RecordsModel

@Observable
public final class RecordsModel {

    /// SC-cues §3a: the pr.toast is "compact, ≥3s, queued one-at-a-time".
    public static let toastSeconds: Double = 3.0

    // MARK: Observable surface (the views render ONLY this)

    /// The visible in-session celebration toast (nil ⇔ none). One at a time
    /// (SC-cues §3a); the view auto-advances after `toastSeconds`.
    public private(set) var currentToast: PRToast?
    /// FIFO queue behind the visible toast — sets finishing fast queue rather
    /// than stack (SC-cues §3a); celebration never escalates in-session
    /// (SC-prs BR-011 — Summary owns escalation).
    public private(set) var queuedToasts: [PRToast] = []

    // MARK: Engines & seams (driven, never reimplemented)

    private let prDAO: PersonalRecordDAO
    private let exerciseDAO: ExerciseDAO
    private let settingsDAO: SettingsDAO
    /// The abstract cue channel — concrete CueDispatcher in production,
    /// a spy in tests.
    private let cueChannel: any FullCueDispatching

    public init(
        prDAO: PersonalRecordDAO,
        exerciseDAO: ExerciseDAO,
        settingsDAO: SettingsDAO,
        cueChannel: any FullCueDispatching
    ) {
        self.prDAO = prDAO
        self.exerciseDAO = exerciseDAO
        self.settingsDAO = settingsDAO
        self.cueChannel = cueChannel
    }

    // MARK: Live path — set completion (SC-prs BR-002/BR-006)

    /// Evaluate the just-completed work set. Called by the workout flow AFTER
    /// the FSM's planned→completed transition committed (post-commit witness,
    /// SC-cues BR-011 — a PR evaluation can never interpose on the ✓ path).
    ///
    /// Behavior is the frozen engine's: first-touch (no baseline row) writes
    /// nothing and cues nothing (BR-002); failed/dropped/warmup sets are
    /// gated out upstream and by BR-001; strict exceed only (BR-003). When a
    /// baseline beats, the row updates transactionally and exactly ONE
    /// cue.pr.achieved fires (celebration class, headline per BR-005). The
    /// toast appears only if the engine actually dispatched — the
    /// backgrounded gate (SC-cues BR-005) suppresses it foreground-only.
    public func setCompleted(setId: String) {
        do {
            guard let write = try prDAO.writeFromSet(setId), let fired = write.fired else {
                return   // first-touch / gated: silent (BR-002)
            }
            // SC-cues BR-008: the PR cue evaluates BEFORE the completion tick
            // so the celebration can subsume it (one haptic per set, INV-C4).
            let event = CueEvent(
                name: .prAchieved,
                at: Date(),
                setId: setId,
                beatenKinds: write.beaten.map(\.rawValue)
            )
            let dispatches = cueChannel.dispatch(event)
            guard dispatches.first != nil else { return }   // suppressed (e.g. backgrounded) → no toast
            enqueueToast(for: fired)
        } catch {
            // A records failure must never reach the money screen: the ✓
            // path committed; the celebration is a witness, not a boss.
        }
    }

    // MARK: Maintenance path — corrections (SC-prs BR-007/BR-008/BR-009)

    /// Editing a COMPLETED set re-derives the exercise's record book so it
    /// always reflects truth (ticket AC). Silent by construction — re-derivation
    /// never cues (BR-009: no retroactive promotion). Delete flows route here
    /// too once a set-tombstone surface ships (BR-008); the live session's
    /// drop/undo never touches rows (dropped sets carry no actuals, BR-001).
    public func rederive(exerciseId: String) {
        try? prDAO.rederive(exerciseId: exerciseId)
    }

    // MARK: Summary surface (SC-prs BR-010 / INV-PR5)

    /// Session PR cards for the Summary surface, precedence-ordered (BR-005):
    /// 0 rows → no section; 1 → single card; ≥2 → banner above stacked cards
    /// (the escalation flag is `showsSummaryBanner`). Reads at render time,
    /// never writes (INV-PR5), and dispatches `cue.pr.summary` — visual-only,
    /// no haptic/audio (SC-cues §3a).
    public func summaryCards(sessionId: String) -> [PRSummaryCard] {
        guard let rows = try? prDAO.fetchSessionPRs(sessionId: sessionId), !rows.isEmpty else {
            return []
        }
        cueChannel.dispatch(CueEvent(name: .prSummary, at: Date()))
        let unit = currentWeightUnit
        return rows.map { row in
            let kindLabel = UICopy.prKindLabel(row.kind.rawValue)
            let valueText = valueText(kind: row.kind, value: row.value, unit: unit)
            let exerciseName = name(of: row.exerciseId)
            return PRSummaryCard(
                id: row.id,
                exerciseId: row.exerciseId,
                exerciseName: exerciseName,
                kindRaw: row.kind.rawValue,
                kindLabel: kindLabel,
                valueText: valueText,
                text: UICopy.summaryPrCard(exerciseName: exerciseName, kindLabel: kindLabel, value: valueText)
            )
        }
    }

    /// BR-010 escalation: ≥2 session PRs ⇒ the banner above stacked cards.
    public static func showsSummaryBanner(cardCount: Int) -> Bool {
        cardCount >= 2
    }

    // MARK: History badge groundwork (#37 — SC-prs §9 feeds #27)

    /// Per-session PR counts by day — the query the future History screen
    /// binds `history.badge.pr` to. Pass-through to the DAO seam; a storage
    /// hiccup degrades to "no badges", never a crash.
    public func sessionPRBadges() -> [SessionPRBadge] {
        (try? prDAO.fetchSessionPRBadges()) ?? []
    }

    // MARK: Toast queue

    /// The view's auto-advance hook after `toastSeconds`: dismiss the visible
    /// toast and promote the next queued one (SC-cues §3a one-at-a-time FIFO).
    public func advanceToast() {
        if queuedToasts.isEmpty {
            currentToast = nil
        } else {
            currentToast = queuedToasts.removeFirst()
        }
    }

    /// Session-boundary hygiene: a re-attach/start adopts a fresh session —
    /// stale celebrations from the previous one never leak across.
    public func resetCelebrations() {
        currentToast = nil
        queuedToasts = []
    }

    private func enqueueToast(for fired: PRFiredCue) {
        let kindLabel = UICopy.prKindLabel(fired.headlineKind.rawValue)
        let text = UICopy.toastPrNew(
            kindLabel: kindLabel,
            exerciseName: name(of: fired.exerciseId),
            value: valueText(kind: fired.headlineKind, value: fired.value, unit: currentWeightUnit)
        )
        let toast = PRToast(
            id: UUID().uuidString.lowercased(),
            text: text,
            headlineKindRaw: fired.headlineKind.rawValue
        )
        if currentToast == nil {
            currentToast = toast
        } else {
            queuedToasts.append(toast)
        }
    }

    // MARK: Internals

    /// SC-settings BR-001: the display unit is read at render time; storage
    /// stays canonical kg (INV-ST2).
    private var currentWeightUnit: WeightUnit {
        (try? settingsDAO.fetchSettings().weightUnit) ?? .kg
    }

    private func name(of exerciseId: String) -> String {
        (try? exerciseDAO.getById(exerciseId))?.name ?? exerciseId
    }

    /// {value} render per kind (SC-prs §6): weight-dimensioned kinds ride the
    /// display unit (SC-settings BR-002 frozen "220.5 lb" shape); reps and
    /// duration are unit-free.
    private func valueText(kind: PRKind, value: Double, unit: WeightUnit) -> String {
        switch kind {
        case .max1rm, .maxVolume:
            return SettingsEngine.displayString(rawKg: value, unit: unit)
        case .maxReps:
            return "\(Int(value))"
        case .maxDuration:
            return "\(Int(value))s"
        }
    }
}
