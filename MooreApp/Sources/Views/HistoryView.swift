// Ticket #33 — History tab placeholder. The full month-grouped session list is
// #37; the shell ships the tab with its contract empty state (#14 §3: answers
// "what will I see here later" without blocking, never fakes content). The CTA
// deep-links to Home (tab switch) per the #14 resolution.

import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MooreColor.steelBase)
            .navigationTitle(UICopy.tabHistory)
        }
    }
}
