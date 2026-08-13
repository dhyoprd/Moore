// Ticket #34 — session summary surface (SC-workout-logging §6 + ticket AC:
// "finishing lands on a session summary with the plan-vs-actual table").
// Shown after finishSession stamps endedAt; the planned column is the
// materialised snapshot (INV-W3 — immutable for the session's life) and the
// actual column is what the lifter logged. Done collapses back to Home.
//
// #40: the summary container rides the Tier 1 shell glass (SC-visual-system)
// as a header panel with the rim-light signature; the plan-vs-actual rows
// stay OPAQUE steel cards — no blur over set rows, ever.
//
// Thin view: the summary value type is built by WorkoutSessionModel.

import SwiftUI
import MooreWorkout

struct WorkoutSummaryView: View {
    let summary: SessionSummary
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            // Tier 1 glass container panel: title + subtitle chrome.
            VStack(spacing: DesignTokens.Spacing.s) {
                // workout.finish.title
                Text(UICopy.workoutFinishTitle)
                    .font(MooreFont.display(.title2))
                    .foregroundStyle(MooreColor.textPrimary)

                // workout.finish.subtitle — "{setsDone} sets · {volumeKg} kg"
                Text(UICopy.workoutFinishSubtitle(setsDone: summary.setsDone, volumeKg: summary.volumeKg))
                    .font(MooreFont.numeric(.subheadline))
                    .foregroundStyle(MooreColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.l)
            .padding(.horizontal, DesignTokens.Spacing.l)
            .mooreGlass(cornerRadius: DesignTokens.Radius.tier3)
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.top, DesignTokens.Spacing.l)

            // The Summary celebrates the day (SC-prs BR-010 / cue.pr.summary
            // visual, #36): 0 session PRs → no section; 1 → single card; ≥2 →
            // "🏆 {n} new PRs" banner above stacked cards, precedence-ordered.
            // Summary owns ALL escalation — in-session never escalates (BR-011).
            if !summary.prCards.isEmpty {
                VStack(spacing: DesignTokens.Spacing.s) {
                    if RecordsModel.showsSummaryBanner(cardCount: summary.prCards.count) {
                        // summary.pr.banner
                        Text(UICopy.summaryPrBanner(count: summary.prCards.count))
                            .font(MooreFont.display(.headline))
                            .foregroundStyle(MooreColor.lime)
                            .moorePRCelebration()
                    }
                    ForEach(summary.prCards) { card in
                        prCard(card)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.l)
            }

            // Plan-vs-actual table.
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.s) {
                    ForEach(summary.rows) { row in
                        summaryRow(row)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.l)
            }

            Button(UICopy.workoutEditAccept) {
                onDone()
            }
            .buttonStyle(MoorePrimaryButtonStyle())
            .padding(.bottom, DesignTokens.Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MooreColor.steelBase)
    }

    /// One plan-vs-actual row: exercise name, planned snapshot, logged actual
    /// (doneDelta / failedDelta / dropped shapes from the contract copy).
    private func summaryRow(_ row: SessionSummaryRow) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Text(row.exerciseName)
                    .font(MooreFont.display(.subheadline))
                    .foregroundStyle(MooreColor.textPrimary)
                Spacer()
                statusTag(row.status)
            }
            HStack(alignment: .firstTextBaseline) {
                // Planned column (the INV-W3 snapshot).
                VStack(alignment: .leading, spacing: 2) {
                    Text(UICopy.workoutSummaryPlanned)
                        .font(MooreFont.body(.caption2))
                        .foregroundStyle(MooreColor.textSecondary.opacity(0.8))
                    Text(row.plannedText)
                        .font(MooreFont.numeric(.subheadline))
                        .foregroundStyle(MooreColor.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(MooreColor.textSecondary.opacity(0.6))
                Spacer()
                // Actual column.
                Text(row.actualText.isEmpty ? "—" : row.actualText)
                    .font(MooreFont.numeric(.subheadline))
                    .foregroundStyle(row.status == .completed ? MooreColor.textPrimary : MooreColor.textSecondary)
                    .strikethrough(row.status == .dropped)
                    .multilineTextAlignment(.trailing)
            }
        }
        .mooreCard()
    }

    private func statusTag(_ status: SetStatus) -> some View {
        Group {
            switch status {
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(MooreColor.lime)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(MooreColor.textSecondary)
            case .dropped:
                Image(systemName: "minus.circle").foregroundStyle(MooreColor.textSecondary.opacity(0.6))
            case .planned:
                EmptyView()
            }
        }
        .font(.subheadline)
    }
}
