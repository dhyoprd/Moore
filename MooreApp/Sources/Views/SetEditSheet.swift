// Ticket #34 — the bottom-sheet edit path (SC-workout-logging@1.0.0).
//
// BR-005: rows carry NO inline steppers — editing is exclusively this sheet,
// a 3-tap path for the 20% case (open → adjust → Done). One sheet serves four
// transitions (§2a): editAndAccept (planned log), fail (swipe-left Failed,
// BR-002 — pre-tagged failed, weight pre-filled, reps focused), editCompleted
// and editFailed (post-completion corrections, BR-006 — no rest re-trigger).
//
// #40: Tier 2 glass chrome (SC-visual-system sheets/modals tier) — dark glass
// presentation + rim-light top hairline; the steel cards/fields ride above it.
//
// Thin view: Done maps to exactly one FsmAction via model.commitEdit; values
// travel in the display unit and convert to canonical kg in the model
// (SC-settings INV-ST2).

import SwiftUI
import MooreWorkout
import MooreSettings

struct SetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    var model: WorkoutSessionModel
    let request: SetEditRequest

    // Field state in the ACTIVE DISPLAY UNIT / raw counts. nil ⇄ 0 bridge:
    // 0 is not a meaningful plan, so 0 stores NULL and NULL displays 0 (the
    // same convention the routine editor uses).
    @State private var displayWeight: Double
    @State private var reps: Int
    @State private var durationSec: Int
    @FocusState private var repsFocused: Bool

    init(model: WorkoutSessionModel, request: SetEditRequest) {
        self.model = model
        self.request = request
        let unit = model.weightUnit
        _displayWeight = State(initialValue: request.weightKg.map {
            SettingsEngine.displayValue(rawKg: $0, unit: unit)
        } ?? 0)
        _reps = State(initialValue: request.reps ?? 0)
        _durationSec = State(initialValue: request.durationSec ?? 0)
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            // workout.edit.title / workout.edit.failTitle
            VStack(spacing: DesignTokens.Spacing.xs) {
                Text(request.isFailMode ? UICopy.workoutEditFailTitle : UICopy.workoutEditTitle)
                    .font(MooreFont.display(.title3))
                    .foregroundStyle(MooreColor.textPrimary)
                Text(request.exerciseName)
                    .font(MooreFont.body(.subheadline))
                    .foregroundStyle(MooreColor.textSecondary)
            }
            .padding(.top, DesignTokens.Spacing.l)

            if request.isDurationMetric {
                durationField
            } else {
                weightField
                repsField
            }

            if model.errorMessage != nil {
                // Keep the sheet honest: surface a refused transition inline.
                Text(model.errorMessage ?? "")
                    .font(MooreFont.numeric(.caption))
                    .foregroundStyle(MooreColor.textSecondary)
            }

            // workout.edit.accept — the 3rd tap.
            Button(UICopy.workoutEditAccept) {
                if model.commitEdit(
                    displayWeight: request.isDurationMetric ? nil : (displayWeight == 0 ? nil : displayWeight),
                    reps: request.isDurationMetric ? nil : (reps == 0 ? nil : reps),
                    durationSec: request.isDurationMetric ? (durationSec == 0 ? nil : durationSec) : nil
                ) {
                    dismiss()
                }
            }
            .buttonStyle(MoorePrimaryButtonStyle())
            // BR-002: failing requires the actual count — the CTA disables
            // until reps exist (copy, not a toast).
            .disabled(doneDisabled)
            .opacity(doneDisabled ? 0.4 : 1)
            .padding(.bottom, DesignTokens.Spacing.l)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.Spacing.l)
        // #40: Tier 2 glass (sheets/modals tier) — the opaque steel gave way
        // to the static dark glass + rim-light; the money screen beneath
        // stays opaque (the glass rides ABOVE it, never in it).
        .mooreSheetGlass()
        .preferredColorScheme(.dark)
        .onAppear {
            if request.mode == .fail {
                repsFocused = true
            }
        }
    }

    private var doneDisabled: Bool {
        switch request.mode {
        case .fail:
            return request.isDurationMetric ? durationSec == 0 : reps == 0
        case .log, .correctCompleted, .correctFailed:
            return false
        }
    }

    // MARK: Weight — stepper + unit toggle + plate preview

    private var weightField: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            HStack {
                // workout.edit.weightLabel
                Text(UICopy.workoutEditWeightLabel)
                    .font(MooreFont.body(.subheadline))
                    .foregroundStyle(MooreColor.textSecondary)
                Spacer()
                Text(weightDisplayText)
                    .font(MooreFont.numeric(.title3))
                    .foregroundStyle(MooreColor.textPrimary)
                // Unit toggle (SC-settings BR-001: display-only write).
                Button(model.weightUnit == .kg ? "lb" : "kg") {
                    toggleUnit()
                }
                .buttonStyle(MooreSecondaryButtonStyle())
            }
            Stepper(
                UICopy.workoutEditWeightLabel,
                value: $displayWeight,
                in: 0...1000,
                step: model.weightUnit == .kg ? 2.5 : 5
            )
            .labelsHidden()

            if request.showsPlatePreview {
                platePreview
            }
        }
        .mooreCard()
    }

    private var weightDisplayText: String {
        String(format: "%.1f %@", displayWeight, model.weightUnit.rawValue)
    }

    /// Barbell plate load per side (20 kg bar): emergent dropsets want to SEE
    /// the plates. Computed from canonical kg regardless of display unit.
    private var platePreview: some View {
        let kg = SettingsEngine.entryToStorage(displayWeight, unit: model.weightUnit)
        return Text(plateText(totalKg: kg))
            .font(MooreFont.numeric(.caption))
            .foregroundStyle(MooreColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func plateText(totalKg: Double) -> String {
        let barKg = 20.0
        guard totalKg >= barKg else { return "Bar only — 20 kg" }
        var perSide = (totalKg - barKg) / 2
        let plates: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]
        var parts: [String] = []
        for plate in plates {
            let count = Int(perSide / plate)
            if count > 0 {
                parts.append(count == 1 ? formatPlate(plate) : "\(count)×\(formatPlate(plate))")
                perSide -= Double(count) * plate
            }
        }
        guard !parts.isEmpty else { return "Bar only — 20 kg" }
        return parts.joined(separator: " + ") + " per side"
    }

    private func formatPlate(_ plate: Double) -> String {
        plate == plate.rounded() ? String(Int(plate)) : String(plate)
    }

    // MARK: Reps — stepper; fail flow gets the focused field (BR-002)

    private var repsField: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            HStack {
                // workout.edit.repsLabel
                Text(UICopy.workoutEditRepsLabel)
                    .font(MooreFont.body(.subheadline))
                    .foregroundStyle(MooreColor.textSecondary)
                Spacer()
                Text("\(reps)")
                    .font(MooreFont.numeric(.title3))
                    .foregroundStyle(MooreColor.textPrimary)
            }
            if request.mode == .fail {
                // The user types the actual count hit — zero-data failure was
                // rejected (#2); this field is the BR-002 seam.
                TextField(UICopy.workoutEditActualRepsPlaceholder, value: $reps, format: .number)
                    .keyboardType(.numberPad)
                    .focused($repsFocused)
                    .font(MooreFont.numeric(.title3))
                    .multilineTextAlignment(.center)
                    .padding(DesignTokens.Spacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.tier3)
                            .fill(MooreColor.steelBase)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.tier3)
                            .strokeBorder(MooreColor.steelHairline, lineWidth: 1)
                    )
            } else {
                Stepper(UICopy.workoutEditRepsLabel, value: $reps, in: 0...100, step: 1)
                    .labelsHidden()
            }
        }
        .mooreCard()
    }

    // MARK: Duration (duration-metric exercises)

    private var durationField: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            HStack {
                // workout.edit.durationLabel
                Text(UICopy.workoutEditDurationLabel)
                    .font(MooreFont.body(.subheadline))
                    .foregroundStyle(MooreColor.textSecondary)
                Spacer()
                Text(UICopy.restOverlayRemaining(seconds: durationSec))
                    .font(MooreFont.numeric(.title3))
                    .foregroundStyle(MooreColor.textPrimary)
            }
            Stepper(UICopy.workoutEditDurationLabel, value: $durationSec, in: 0...3600, step: 5)
                .labelsHidden()
        }
        .mooreCard()
    }

    // MARK: Unit toggle

    /// Converts the in-flight field through canonical kg so the toggle never
    /// changes the value, only its display (SC-settings BR-001).
    private func toggleUnit() {
        let oldUnit = model.weightUnit
        let canonicalKg = SettingsEngine.entryToStorage(displayWeight, unit: oldUnit)
        model.toggleWeightUnit()
        displayWeight = SettingsEngine.displayValue(rawKg: canonicalKg, unit: model.weightUnit)
    }
}
