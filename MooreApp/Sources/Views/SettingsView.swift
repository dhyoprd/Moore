// Ticket #33 — Settings tab placeholder. The full surface (units, rest defaults,
// body metrics, data & sync, tombstone management) is #38; the shell ships the
// tab with its contract title + the five sub-screen rows (SC-settings §6 titles),
// inert until #38 wires them.

import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    settingsRow(UICopy.settingsUnitsTitle)
                    settingsRow(UICopy.settingsRestDefaultsTitle)
                    settingsRow(UICopy.settingsBodyMetricsTitle)
                    settingsRow(UICopy.settingsDataSyncTitle)
                    settingsRow(UICopy.settingsCloudSyncTitle)
                    settingsRow(UICopy.settingsTombstonesTitle)
                }
            }
            .scrollContentBackground(.hidden)
            .background(MooreColor.steelBase)
            // settings.title
            .navigationTitle(UICopy.settingsTitle)
        }
    }

    private func settingsRow(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(MooreFont.body())
                .foregroundStyle(MooreColor.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(MooreColor.textSecondary.opacity(0.6))
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}
