// Ticket #33 — Analytics tab placeholder. The full derived-queries surface is
// #37; per #14 §3 Analytics always RENDERS (never hides) — zero-state page,
// typography-only, no empty chart frames. The CTA deep-links to Home.

import SwiftUI

struct AnalyticsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            VStack(spacing: DesignTokens.Spacing.l) {
                Spacer()
                // analytics.empty_title
                Text(UICopy.analyticsEmptyTitle)
                    .font(MooreFont.display(.largeTitle))
                    .foregroundStyle(MooreColor.textPrimary)
                // analytics.empty_sub
                Text(UICopy.analyticsEmptySub)
                    .font(MooreFont.body())
                    .foregroundStyle(MooreColor.textSecondary)
                    .multilineTextAlignment(.center)
                // analytics.empty_cta → deep-link to Home
                Button(UICopy.analyticsEmptyCta) {
                    appState.selectedTab = .home
                }
                .buttonStyle(MoorePrimaryButtonStyle())
                // analytics.hint_body
                Text(UICopy.analyticsHintBody)
                    .font(MooreFont.body(.footnote))
                    .foregroundStyle(MooreColor.textSecondary.opacity(0.8))
                Spacer()
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MooreColor.steelBase)
            .navigationTitle(UICopy.tabAnalytics)
        }
    }
}
