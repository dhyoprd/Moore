// Ticket #37 — History tab: month-grouped sessions with inline PR badges
// (SC-analytics BR-006 / SC-prs §6 `history.badge.pr`). Tap → session detail
// with the plan-vs-actual table + per-exercise e1RM sparklines (BR-007).
//
// Thin view: ALL query/aggregation logic lives in HistoryModel (Foundation-only,
// driving the frozen AnalyticsEngine/AnalyticsDAO + the #36 badge probe); this
// layer only lays out render-ready values. Zero sessions renders the contracted
// #14 empty state — present from session zero, never an unlock threshold (BR-008).

import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MooreColor.steelBase)
                .navigationTitle(UICopy.historyTitle)
        }
        // Cold-render rule: re-derive from SQLite every time the tab surfaces.
        .onAppear { appState.history?.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if let model = appState.history {
            if model.months.isEmpty {
                emptyState
            } else {
                HistoryList(model: model)
            }
        } else {
            EmptyView()   // boot failure owns the surface (FatalBootView)
        }
    }

    /// Zero-data surface (#14 §3 / SC-analytics BR-008): honest empty state,
    /// CTA deep-links to Home — no unlock threshold, never hidden.
    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            Spacer()
            // history.empty_title
            Text(UICopy.historyEmptyTitle)
                .font(MooreFont.display(.largeTitle))
                .foregroundStyle(MooreColor.textPrimary)
            // history.empty_sub
            Text(UICopy.historyEmptySub)
                .font(MooreFont.body())
                .foregroundStyle(MooreColor.textSecondary)
                .multilineTextAlignment(.center)
            // history.empty_cta → deep-link to Home
            Button(UICopy.historyEmptyCta) {
                appState.selectedTab = .home
            }
            .buttonStyle(MoorePrimaryButtonStyle())
            Spacer()
        }
        .padding(DesignTokens.Spacing.xl)
    }
}

// MARK: - Month-grouped list (BR-006)

private struct HistoryList: View {
    let model: HistoryModel

    var body: some View {
        List {
            ForEach(model.months) { section in
                Section {
                    ForEach(section.rows) { row in
                        NavigationLink(value: row.sessionId) {
                            HistorySessionRowView(row: row)
                        }
                        .listRowBackground(MooreColor.steelRaised)
                        .listRowSeparatorTint(MooreColor.steelHairline)
                    }
                } header: {
                    // history.monthHeader — "{monthName} {year}"
                    Text(section.monthTitle)
                        .font(MooreFont.display(.footnote))
                        .foregroundStyle(MooreColor.textSecondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MooreColor.steelBase)
        .navigationDestination(for: String.self) { sessionId in
            SessionDetailView(model: model, sessionId: sessionId)
        }
    }
}

// MARK: - Session row

private struct HistorySessionRowView: View {
    let row: HistorySessionRow

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(MooreFont.display(.subheadline))
                    .foregroundStyle(MooreColor.textPrimary)
                    .lineLimit(1)
                Spacer()
                // history.badge.pr renders iff prCount > 0 (SC-prs §6).
                if row.showsPrBadge {
                    Text(UICopy.historyBadgePr)
                        .mooreChip()
                }
            }
            // history.session.sets + day + work-set tonnage.
            HStack(spacing: DesignTokens.Spacing.s) {
                Text(row.dateText)
                    .font(MooreFont.body(.caption))
                    .foregroundStyle(MooreColor.textSecondary)
                Text("·")
                    .font(MooreFont.body(.caption))
                    .foregroundStyle(MooreColor.textSecondary.opacity(0.6))
                Text(row.setsText)
                    .font(MooreFont.numeric(.caption))
                    .foregroundStyle(MooreColor.textSecondary)
                if let tonnage = row.tonnageText {
                    Text("·")
                        .font(MooreFont.body(.caption))
                        .foregroundStyle(MooreColor.textSecondary.opacity(0.6))
                    Text(tannage)
                        .font(MooreFont.numeric(.caption))
                        .foregroundStyle(MooreColor.textSecondary)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}
