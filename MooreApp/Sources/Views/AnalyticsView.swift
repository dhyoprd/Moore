// Ticket #37 — Analytics tab (SC-analytics@1.0.0): STRICTLY DERIVED — every
// number recomputes from CompletedSet at read time (INV-A1; no stored
// aggregates). Sections: streak/adherence header (BR-001/BR-010), Epley 1RM
// trend with >7-day gap breaks (BR-002/INV-A3), weekly tonnage excluding
// warmups (BR-003), muscle split summing to 100% ± 0.1% (BR-004), and the
// reverse-chronological PR list (BR-005).
//
// Thin view: ALL query/aggregation logic lives in AnalyticsModel (Foundation-
// only, driving the frozen AnalyticsEngine/AnalyticsDAO); this layer only lays
// out render-ready values with DesignSystem tokens + Swift Charts.
//
// BR-008 — empty is RENDERED, never gated: every section always shows its
// container; zero data renders the §6 empty copy ("Log 3 sessions to see
// trends" is encouragement, not an unlock threshold).

import SwiftUI
import Charts

struct AnalyticsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            content
                .background(MooreColor.steelBase)
                .navigationTitle(UICopy.analyticsTitle)
        }
        // Cold-render rule: re-derive from SQLite every time the tab surfaces.
        .onAppear { appState.analytics?.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if let model = appState.analytics {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    headerCards(model)
                    trendSection(model)
                    tonnageSection(model)
                    splitSection(model)
                    prSection(model)
                }
                .padding(DesignTokens.Spacing.l)
            }
        } else {
            EmptyView()   // boot failure owns the surface (FatalBootView)
        }
    }

    // MARK: Header — streak + adherence (BR-001 / BR-010)

    private func headerCards(_ model: AnalyticsModel) -> some View {
        HStack(spacing: DesignTokens.Spacing.l) {
            // Streak card.
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                // analytics.streak.title
                Text(UICopy.analyticsStreakTitle)
                    .font(MooreFont.body(.caption))
                    .foregroundStyle(MooreColor.textSecondary)
                if model.streakDays > 0 {
                    // analytics.streak.days — "{n} days"
                    Text(UICopy.analyticsStreakDays(model.streakDays))
                        .font(MooreFont.display(.title3))
                        .foregroundStyle(MooreColor.lime)
                } else {
                    // analytics.streak.none — 0 reads "No streak yet", never hidden.
                    Text(UICopy.analyticsStreakNone)
                        .font(MooreFont.body(.subheadline))
                        .foregroundStyle(MooreColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .mooreCard()

            // Session counts card (7-day / 30-day).
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                // analytics.header.last7 / last30
                Text(model.last7Text)
                    .font(MooreFont.numeric(.subheadline))
                    .foregroundStyle(MooreColor.textPrimary)
                Text(model.last30Text)
                    .font(MooreFont.numeric(.subheadline))
                    .foregroundStyle(MooreColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .mooreCard()
        }
    }

    // MARK: Epley 1RM trend (BR-002)

    private func trendSection(_ model: AnalyticsModel) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                // analytics.trend.title
                Text(UICopy.analyticsTrendTitle)
                    .font(MooreFont.display(.headline))
                    .foregroundStyle(MooreColor.textPrimary)
                Spacer()
                if model.trendOptions.count > 1 {
                    exercisePicker(model)
                } else if let only = model.trendOptions.first {
                    Text(only.name)
                        .font(MooreFont.body(.caption))
                        .foregroundStyle(MooreColor.textSecondary)
                }
            }

            if model.trendPoints.isEmpty {
                emptyLine(UICopy.analyticsEmptyTrends)
            } else {
                trendChart(model.trendPoints)
            }
        }
        .mooreCard()
    }

    private func exercisePicker(_ model: AnalyticsModel) -> some View {
        Picker(UICopy.analyticsTrendTitle, selection: trendSelection(model)) {
            ForEach(model.trendOptions) { option in
                Text(option.name).tag(Optional(option.id))
            }
        }
        .pickerStyle(.menu)
        .tint(MooreColor.textSecondary)
    }

    private func trendSelection(_ model: AnalyticsModel) -> Binding<String?> {
        Binding(
            get: { model.selectedTrendExerciseId },
            set: { model.selectTrendExercise($0) }
        )
    }

    /// One line per `segment` — a >7-day gap between points breaks the line
    /// (BR-002 / INV-A3); the engine never zero-fills, so no phantom flat lines.
    private func trendChart(_ points: [TrendPointDisplay]) -> some View {
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
                .symbolSize(28)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(MooreColor.steelHairline)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(MooreColor.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(MooreColor.steelHairline)
                AxisValueLabel().foregroundStyle(MooreColor.textSecondary)
            }
        }
        .chartLegend(.hidden)
        .frame(height: 200)
    }

    // MARK: Weekly tonnage (BR-003 — warmups excluded)

    private func tonnageSection(_ model: AnalyticsModel) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            // analytics.tonnage.title
            Text(UICopy.analyticsTonnageTitle)
                .font(MooreFont.display(.headline))
                .foregroundStyle(MooreColor.textPrimary)

            if model.tonnageBars.isEmpty {
                emptyLine(UICopy.analyticsEmptyTrends)
            } else {
                Chart(model.tonnageBars) { bar in
                    BarMark(
                        x: .value("Week", bar.week),
                        y: .value("Tonnage", bar.tonnage)
                    )
                    .foregroundStyle(MooreColor.lime)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel().foregroundStyle(MooreColor.textSecondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(MooreColor.steelHairline)
                        AxisValueLabel().foregroundStyle(MooreColor.textSecondary)
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 160)
            }
        }
        .mooreCard()
    }

    // MARK: Muscle split (BR-004 — pct sums to 100 ± 0.1%)

    private func splitSection(_ model: AnalyticsModel) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            // analytics.split.title
            Text(UICopy.analyticsSplitTitle)
                .font(MooreFont.display(.headline))
                .foregroundStyle(MooreColor.textPrimary)

            if model.splitRows.isEmpty {
                emptyLine(UICopy.analyticsEmptyTrends)
            } else {
                ForEach(model.splitRows) { row in
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            // analytics.split.bucket.upper/lower/other
                            Text(row.label)
                                .font(MooreFont.display(.subheadline))
                                .foregroundStyle(MooreColor.textPrimary)
                            Spacer()
                            Text(row.pctText)
                                .font(MooreFont.numeric(.subheadline))
                                .foregroundStyle(MooreColor.textPrimary)
                        }
                        ProgressView(value: row.pct, total: 100)
                            .tint(MooreColor.lime)
                        Text(row.tonnageText)
                            .font(MooreFont.numeric(.caption2))
                            .foregroundStyle(MooreColor.textSecondary)
                    }
                }
            }
        }
        .mooreCard()
    }

    // MARK: PR list (BR-005 — reverse-chronological)

    private func prSection(_ model: AnalyticsModel) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            // analytics.prs.title
            Text(UICopy.analyticsPrsTitle)
                .font(MooreFont.display(.headline))
                .foregroundStyle(MooreColor.textPrimary)

            if model.prRows.isEmpty {
                // analytics.empty.prs
                emptyLine(UICopy.analyticsEmptyPrs)
            } else {
                ForEach(model.prRows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.exerciseName)
                                .font(MooreFont.display(.subheadline))
                                .foregroundStyle(MooreColor.textPrimary)
                            Text(row.kindLabel)
                                .font(MooreFont.body(.caption))
                                .foregroundStyle(MooreColor.textSecondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.valueText)
                                .font(MooreFont.numeric(.subheadline))
                                .foregroundStyle(MooreColor.lime)
                            Text(row.dayText)
                                .font(MooreFont.body(.caption2))
                                .foregroundStyle(MooreColor.textSecondary)
                        }
                    }
                    if row.id != model.prRows.last?.id {
                        Divider().overlay(MooreColor.steelHairline)
                    }
                }
            }
        }
        .mooreCard()
    }

    // MARK: Shared

    /// §6 empty copy line — the container is present from session zero;
    /// the copy invites, never gates (BR-008).
    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(MooreFont.body(.footnote))
            .foregroundStyle(MooreColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DesignTokens.Spacing.m)
    }
}
