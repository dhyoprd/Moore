// Ticket #34 — the ambient rest overlay + Finish-morph panel (SC-rest@1.0.0).
//
// §2a surface: rest auto-starts on every completed/failed set; countdown +
// Skip / −15s / +15s; expiry flips to the rest-over state (informational only
// — the set list stays actionable, INV-T5). §2b surface: when the run being
// consumed belongs to the final terminal set, its expiry/skip morphs the
// overlay into the Finish panel — the morph IS the cue (visual only, #10).
//
// Glass tier: the overlay rides the secondary glass tier (sheets/overlays per
// the token table) over the opaque-steel money screen — #40: the shared
// mooreGlass modifier with the rim-light signature.
//
// Thin view: countdowns are computed from the model's timestamps (BR-007 —
// never ticked, never stored); transitions live in WorkoutSessionModel.

import SwiftUI
import MooreRest

struct RestOverlayView: View {
    @Environment(AppState.self) private var appState
    var model: WorkoutSessionModel
    let now: Date

    /// #40: alert emphasis trigger — bumped on appear and on every rest.over
    /// pulse from the cue renderer (SC-cues INV-C3: the visual floor always
    /// lands, even silenced).
    @State private var alertPulse = 0

    var body: some View {
        switch model.restCycle.state {
        case .restRunning:
            runningPanel
        case .restExpired:
            restOverPanel
        case .noRest:
            EmptyView()
        }
    }

    /// The cue renderer's latest rest.over pulse id (nil ⇄ none yet).
    private var restOverPulseId: UInt64? {
        guard let pulse = appState.cueVisualPulse?.latest, pulse.element == "rest.over" else { return nil }
        return pulse.id
    }

    // MARK: Running — countdown + the three affordances

    private var runningPanel: some View {
        VStack(spacing: DesignTokens.Spacing.m) {
            // rest.overlay.title
            Text(UICopy.restOverlayTitle)
                .font(MooreFont.display(.subheadline))
                .foregroundStyle(MooreColor.textSecondary)

            // rest.overlay.remaining — "{mm:ss}", numeric-mono register.
            Text(UICopy.restOverlayRemaining(seconds: max(0, model.restRemainingSec(at: now))))
                .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                .foregroundStyle(MooreColor.textPrimary)
                .contentTransition(.numericText(countsDown: true))
                .animation(.linear(duration: 0.2), value: model.restRemainingSec(at: now))

            HStack(spacing: DesignTokens.Spacing.l) {
                // rest.overlay.cta.minus15 — one-off, never persisted (BR-002)
                Button(UICopy.restOverlayCtaMinus15) {
                    model.adjustRest(delta: -15)
                }
                .buttonStyle(MooreSecondaryButtonStyle())

                // rest.overlay.cta.skip — instant cancel, no cue (BR-003)
                Button(UICopy.restOverlayCtaSkip) {
                    model.skipRest()
                }
                .buttonStyle(MoorePrimaryButtonStyle())

                // rest.overlay.cta.plus15
                Button(UICopy.restOverlayCtaPlus15) {
                    model.adjustRest(delta: 15)
                }
                .buttonStyle(MooreSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.l)
        .mooreGlass(cornerRadius: DesignTokens.Radius.tier3)
    }

    // MARK: Rest over — expiry is informational only (INV-T5)

    private var restOverPanel: some View {
        VStack(spacing: DesignTokens.Spacing.m) {
            // rest.over.title
            Text(UICopy.restOverTitle)
                .font(MooreFont.display(.subheadline))
                .foregroundStyle(MooreColor.textSecondary)

            // rest.over.body — "{exerciseName} — set {n} of {total}"
            if let next = model.restOverDescription {
                Text(UICopy.restOverBody(exerciseName: next.exerciseName, n: next.n, total: next.total))
                    .font(MooreFont.body(.subheadline))
                    .foregroundStyle(MooreColor.textPrimary)
            }

            Button(UICopy.restOverlayCtaSkip) {
                model.skipRest()   // dismisses the rest-over state to noRest
            }
            .buttonStyle(MooreSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.l)
        .mooreGlass(cornerRadius: DesignTokens.Radius.tier3)
        // #40: the alert cue's visual emphasis (SC-cues §3a rest.over): a
        // lime rim flash on the flip — haptic + tone may be silenced, the
        // flash always lands (INV-C3). Lime stays ink: a stroke, never a fill.
        .phaseAnimator([0.0, 0.9, 0.0], trigger: alertPulse) { content, opacity in
            content.overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.tier3)
                    .strokeBorder(MooreColor.lime, lineWidth: 1.5)
                    .opacity(opacity)
                    .allowsHitTesting(false)
            )
        } animation: { _ in
            .easeInOut(duration: 0.35)
        }
        .onAppear { alertPulse += 1 }
        .onChange(of: restOverPulseId) { _, _ in alertPulse += 1 }
    }
}

// MARK: - Finish panel (§2b morph target)

/// Presented when every set is terminal and the final rest run has been
/// consumed (expiry or skip). One tap → finishSession → the summary surface.
struct FinishPanelView: View {
    var model: WorkoutSessionModel
    let now: Date

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.m) {
            // rest.finish.summary — "{setCount} sets · {exerciseCount} exercises · {duration}"
            Text(model.finishPanelText(at: now))
                .font(MooreFont.numeric(.subheadline))
                .foregroundStyle(MooreColor.textPrimary)

            // rest.finish.cta
            Button(UICopy.restFinishCta) {
                _ = model.finish()
            }
            .buttonStyle(MoorePrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.l)
        .mooreGlass(cornerRadius: DesignTokens.Radius.tier3)
    }
}
