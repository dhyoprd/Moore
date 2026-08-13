// Ticket #38 — body-metric add-entry sheet (SC-settings BR-006). Thin form over
// BodyMetricEntryDraft: kind picker (closed post-0011 vocabulary), free label for
// measurements, value + unit per kind-legality, recorded date. Save is gated by
// the pure engine validation (SettingsEngine.validateBodyMetric via draft.isValid);
// the write goes through SettingsModel → SettingsDAO.addBodyMetric, which
// re-validates and rejects with no partial write.

import SwiftUI
import MooreSettings

struct BodyMetricSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BodyMetricEntryDraft

    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        // Entry respect (BR-003): the weight-kind form opens in the active unit.
        _draft = State(initialValue: BodyMetricEntryDraft(weightUnit: model.settings.weightUnit))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    kindPicker
                    if draft.kind == "measurement" {
                        // Free label — REQUIRED for measurements (BR-006).
                        TextField(UICopy.settingsLabelPlaceholder, text: $draft.label)
                            .font(MooreFont.body())
                    }
                    // Numeric value (stored with the row's own unit — INV-ST2).
                    TextField(UICopy.settingsValuePlaceholder, text: $draft.valueText)
                        .keyboardType(.decimalPad)
                        .font(MooreFont.numeric())
                    unitControl
                    // settingsRecordedAtLabel — the recordedAt timeline key.
                    DatePicker(
                        UICopy.settingsRecordedAtLabel,
                        selection: $draft.recordedAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .font(MooreFont.body())
                }
            }
            .scrollContentBackground(.hidden)
            // #40: Tier 2 glass (sheets/modals tier) + rim-light top hairline.
            .mooreSheetGlass()
            // settings.bodyMetrics.addCta doubles as the sheet title.
            .navigationTitle(UICopy.settingsBodyMetricsAddCta)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(UICopy.settingsSheetCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(UICopy.settingsSheetSave) {
                        if model.addBodyMetric(draft) {
                            dismiss()
                        }
                    }
                    .disabled(!draft.isValid)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Fields

    /// §3b closed vocabulary: bodyWeight / bodyFat / measurement. Switching kinds
    /// re-seats the unit to the lawful default for the new kind.
    private var kindPicker: some View {
        Picker(
            UICopy.settingsKindLabel,
            selection: Binding(
                get: { draft.kind },
                set: { draft.setKind($0, weightUnit: model.settings.weightUnit) }
            )
        ) {
            Text(UICopy.settingsKindBodyWeight).tag("bodyWeight")
            Text(UICopy.settingsKindBodyFat).tag("bodyFat")
            Text(UICopy.settingsKindMeasurement).tag("measurement")
        }
        .pickerStyle(.segmented)
    }

    /// Unit legality per kind (§3b): bodyWeight ∈ kg|lb (segmented), bodyFat is
    /// fixed `pct`, measurement takes any non-empty unit string as entered.
    @ViewBuilder
    private var unitControl: some View {
        switch draft.kind {
        case "bodyWeight":
            Picker(UICopy.settingsUnitLabel, selection: $draft.unit) {
                Text(WeightUnit.kg.rawValue).tag(WeightUnit.kg.rawValue)
                Text(WeightUnit.lb.rawValue).tag(WeightUnit.lb.rawValue)
            }
            .pickerStyle(.segmented)
        case "bodyFat":
            HStack {
                Spacer()
                Text("pct")
                    .font(MooreFont.numeric())
                    .foregroundStyle(MooreColor.textSecondary)
            }
        default:
            TextField(UICopy.settingsUnitPlaceholder, text: $draft.unit)
                .font(MooreFont.body())
                .autocorrectionDisabled()
        }
    }
}
