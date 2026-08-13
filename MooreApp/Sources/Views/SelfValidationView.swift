// Ticket #43 — Self-validation section (the 8-week gate dashboard), rendered
// at the BOTTOM of the Analytics tab. Placement rationale: self-validation is
// analytics about the builder's own usage — the gate verdict is the payoff of
// every metric above it; Settings stays for preferences/data management.
//
// Thin view: ALL derivation lives in ValidationModel/ValidationMetricsEngine
// (Foundation-only); this layer only lays out render-ready values with
// DesignSystem tokens. Everything is local — no network, no third-party
// analytics (AC: nothing phones home).
//
// MAC-BUILD-ONLY: SwiftUI surface — verified by the Mac build, not by the
// Windows parse checks (the Foundation-only model + engine it binds to are
// parse-verified off-Mac).

import SwiftUI

struct SelfValidationSection: View {
    @Bindable var model: ValidationModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
            header
            usageRow
            speedSection
            retentionSection
            gateCard
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            // validation.title
            Text(UICopy.validationTitle)
                .font(MooreFont.display(.title3))
                .foregroundStyle(MooreColor.textPrimary)
            // validation.subtitle
            Text(UICopy.validationSubtitle)
                .font(MooreFont.body(.footnote))
                .foregroundStyle(MooreColor.textSecondary)
        }
    }

    // MARK: This week + week streak (gate condition 1, derived)

    private var usageRow: some View {
        HStack(spacing: DesignTokens.Spacing.l) {
            metricCard(title: UICopy.validationWeekTitle, value: model.currentWeekCountText)
            metricCard(title: UICopy.validationStreakTitle, value: model.weekStreakText)
        }
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(MooreFont.body(.caption))
                .foregroundStyle(MooreColor.textSecondary)
            Text(value)
                .font(MooreFont.numeric(.subheadline))
                .foregroundStyle(MooreColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mooreCard()
    }

    // MARK: Logging speed vs Hevy baseline

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            // validation.speed.title
            Text(UICopy.validationSpeedTitle)
                .font(MooreFont.display(.headline))
                .foregroundStyle(MooreColor.textPrimary)

            // validation.speed.current — derived median proxy (or empty copy)
            Text(model.speedCurrentText)
                .font(MooreFont.numeric(.subheadline))
                .foregroundStyle(MooreColor.lime)
            // validation.speed.baseline — stored reference (or empty copy)
            Text(model.speedBaselineText)
                .font(MooreFont.numeric(.subheadline))
                .foregroundStyle(MooreColor.textSecondary)

            // Baseline entry: one field + one commit CTA, all local.
            HStack(spacing: DesignTokens.Spacing.m) {
                TextField(UICopy.validationBaselinePlaceholder, text: $model.baselineDraft)
                    .font(MooreFont.numeric(.subheadline))
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                // validation.baseline.save
                Button(UICopy.validationBaselineSave) {
                    model.saveBaseline()
                }
                .font(MooreFont.display(.subheadline))
                .buttonStyle(.borderedProminent)
                .tint(MooreColor.lime)
            }
        }
        .mooreCard()
    }

    // MARK: Retention (app-open cadence)

    private var retentionSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            // validation.retention.title
            Text(UICopy.validationRetentionTitle)
                .font(MooreFont.display(.headline))
                .foregroundStyle(MooreColor.textPrimary)

            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.l) {
                Text(model.retentionWeekText)
                    .font(MooreFont.numeric(.subheadline))
                    .foregroundStyle(MooreColor.textPrimary)
                Text(model.retentionTotalText)
                    .font(MooreFont.numeric(.caption))
                    .foregroundStyle(MooreColor.textSecondary)
            }

            // Sparkline-ish summary: one bar per recent week, height =
            // distinct open days (capped at 7). The engine never zero-fills,
            // so absent weeks render as the floor line, not phantom zeros.
            retentionBars
        }
        .mooreCard()
    }

    private var retentionBars: some View {
        HStack(alignment: .bottom, spacing: DesignTokens.Spacing.s) {
            let recent = model.retentionWeeks.suffix(8)
            if recent.isEmpty {
                Text(UICopy.validationRetentionEmpty)
                    .font(MooreFont.body(.caption2))
                    .foregroundStyle(MooreColor.textSecondary)
            }
            ForEach(Array(recent), id: \.week) { week in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(MooreColor.lime.opacity(week.distinctOpenDays > 0 ? 1.0 : 0.25))
                        .frame(width: 14, height: barHeight(days: week.distinctOpenDays))
                    Text(week.week.suffix(2))
                        .font(MooreFont.numeric(.caption2))
                        .foregroundStyle(MooreColor.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func barHeight(days: Int) -> CGFloat {
        let capped = max(0, min(7, days))
        return 4 + CGFloat(capped) * 6   // 4pt floor, 6pt per open day
    }

    // MARK: The gate card

    private var gateCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                // validation.gate.title
                Text(UICopy.validationGateTitle)
                    .font(MooreFont.display(.headline))
                    .foregroundStyle(MooreColor.textPrimary)
                Spacer()
                // The verdict: PASS / IN-PROGRESS / NOT-STARTED
                Text(model.gateStatusText)
                    .font(MooreFont.display(.subheadline))
                    .foregroundStyle(model.gateStatusText == UICopy.validationGatePass
                                     ? MooreColor.lime : MooreColor.textSecondary)
            }

            // Condition 1 — derived: 2+ sessions/week for 8 consecutive weeks.
            conditionRow(
                met: model.gate?.streakConditionMet ?? false,
                label: UICopy.validationGateStreakCondition,
                detail: model.weekStreakText
            )

            // Condition 2 — manual: displacement, builder attests weekly (#4).
            Toggle(isOn: Binding(
                get: { model.displacementConfirmed },
                set: { model.setDisplacementConfirmed($0) }
            )) {
                Text(UICopy.validationGateDisplacementCondition)
                    .font(MooreFont.body(.footnote))
                    .foregroundStyle(MooreColor.textPrimary)
            }
            .tint(MooreColor.lime)

            // Condition 3 — manual: the week-8 retention answer (#4).
            Toggle(isOn: Binding(
                get: { model.retentionConfirmed },
                set: { model.setRetentionConfirmed($0) }
            )) {
                Text(UICopy.validationGateRetentionCondition)
                    .font(MooreFont.body(.footnote))
                    .foregroundStyle(MooreColor.textPrimary)
            }
            .tint(MooreColor.lime)
        }
        .mooreCard()
    }

    private func conditionRow(met: Bool, label: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.s) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? MooreColor.lime : MooreColor.textSecondary)
            Text(label)
                .font(MooreFont.body(.footnote))
                .foregroundStyle(MooreColor.textPrimary)
            Spacer()
            Text(detail)
                .font(MooreFont.numeric(.caption))
                .foregroundStyle(MooreColor.textSecondary)
        }
    }
}
