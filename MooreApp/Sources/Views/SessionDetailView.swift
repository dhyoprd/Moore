// Ticket #37 — Session detail (SC-analytics BR-007): the session's live sets in
// sortOrder with the dual planned/actual columns side-by-side (INV-5 — the plan
// snapshot stays intact; failed rows keep their recorded actuals, SC-workout-
// logging BR-002), plus the per-exercise e1RM sparkline (BR-002 points over full
// history, segment info intact — a >7-day gap breaks the line, never zero-filled).
//
// Thin view: the detail value graph is built by HistoryModel.loadDetail; this
// layer only lays it out with DesignSystem tokens. Swift Charts renders the
// sparkline as line segments keyed by `segment` so breaks are honest.

import SwiftUI
import Charts

struct SessionDetailView: View {
    let model: HistoryModel
    let sessionId: String

    var body: some View {
        Group {
            if let detail = model.detail, model.detailSessionId == sessionId {
                detailContent(detail)
            } else {
                ProgressView()
                    .tint(MooreColor.lime)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(MooreColor.steelBase)
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.loadDetail(sessionId: sessionId) }
    }

    private var navTitle: String {
        if let detail = model.detail, model.detailSessionId == sessionId {
            return detail.title
        }
        return UICopy.historyTitle
    }

    @ViewBuilder
    private func detailContent(_ detail: SessionDetailDisplay) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                if !detail.dateText.isEmpty {
                    Text(detail.dateText)
                        .font(MooreFont.body(.subheadline))
                        .foregroundStyle(MooreColor.textSecondary)
                }

                if detail.groups.isEmpty {
                    // A session with no live sets: honest empty container.
                    Text(UICopy.analyticsEmptyHistory)
                        .font(MooreFont.body())
                        .foregroundStyle(MooreColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, DesignTokens.Spacing.xxl)
                } else {
                    ForEach(detail.groups) { group in
                        exerciseGroup(group)
                    }
                }
            }
            .padding(DesignTokens.Spacing.l)
        }
    }

    /// One exercise block: name header, the e1RM sparkline, then the
    /// plan-vs-actual rows for the session's sets of that exercise.
    @ViewBuilder
    private func exerciseGroup(_ group: SessionDetailExerciseGroup) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            Text(group.exerciseName)
                .font(MooreFont.display(.headline))
                .foregroundStyle(MooreColor.textPrimary)

            if !group.sparkline.isEmpty {
                sparkline(group.sparkline)
            }

            // Column headers for the dual-column table.
            HStack(spacing: DesignTokens.Spacing.m) {
                // history.detail.planHeader
                Text(UICopy.historyDetailPlanHeader)
                    .font(MooreFont.body(.caption))
                    .foregroundStyle(MooreColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // history.detail.actualHeader
                Text(UICopy.historyDetailActualHeader)
                    .font(MooreFont.body(.caption))
                    .foregroundStyle(MooreColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Trailing status gutter keeps columns aligned with the rows.
                Color.clear.frame(width: 24, height: 1)
            }

            VStack(spacing: DesignTokens.Spacing.s) {
                ForEach(group.rows) { row in
                    planActualRow(row)
                }
            }
        }
        .mooreCard()
    }

    /// One set row: planned column → actual column → status glyph.
    private func planActualRow(_ row: SessionDetailSetRow) -> some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            Text(row.plannedText)
                .font(MooreFont.numeric(.subheadline))
                .foregroundStyle(MooreColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.actualText)
                .font(MooreFont.numeric(.subheadline))
                .foregroundStyle(actualForeground(row))
                .strikethrough(row.status == "dropped", color: MooreColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            statusGlyph(row)
                .frame(width: 24)
        }
    }

    private func actualForeground(_ row: SessionDetailSetRow) -> Color {
        switch row.status {
        case "completed": return MooreColor.textPrimary
        case "failed": return MooreColor.lime
        default: return MooreColor.textSecondary
        }
    }

    @ViewBuilder
    private func statusGlyph(_ row: SessionDetailSetRow) -> some View {
        switch row.status {
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(MooreColor.lime)
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(MooreColor.textSecondary)
        case "dropped":
            Image(systemName: "minus.circle")
                .foregroundStyle(MooreColor.textSecondary.opacity(0.6))
        default:
            Image(systemName: "circle.dotted")
                .foregroundStyle(MooreColor.textSecondary.opacity(0.6))
        }
    }

    /// Per-exercise e1RM sparkline. Line segments are keyed by `segment` so a
    /// >7-day gap renders as a real break (BR-002 / INV-A3), never a phantom
    /// flat line. Warmup/bodyweight rows never plot — the engine gates them.
    private func sparkline(_ points: [SparklinePoint]) -> some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Day", point.date),
                    y: .value("e1RM", point.value),
                    series: .value("Segment", point.segment)
                )
                .foregroundStyle(MooreColor.lime)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("Day", point.date),
                    y: .value("e1RM", point.value)
                )
                .foregroundStyle(MooreColor.lime)
                .symbolSize(18)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 44)
        .accessibilityLabel(Text("\(UICopy.analyticsTrendTitle)"))
    }
}
