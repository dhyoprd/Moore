// Ticket #33 — mini-player bar (#7 §2): persistent above the tab bar on every
// tab while a session is live; content = routine name · sets done/total (same
// data as the Home resume card); one tap re-presents the Active Workout modal.
// Tier 1 glass shell in the full design (#40); steel-raised stand-in here.

import SwiftUI
import MooreRoutines

struct MiniPlayerView: View {
    let session: ActiveSessionSummary
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignTokens.Spacing.m) {
                Image(systemName: "play.fill")
                    .foregroundStyle(MooreColor.lime)
                Text(UICopy.resumeLabel(
                    routineName: session.routineName,
                    setsDone: session.setsDone,
                    setsTotal: session.setsTotal
                ))
                .font(MooreFont.display(.subheadline))
                .foregroundStyle(MooreColor.textPrimary)
                .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MooreColor.textSecondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.vertical, DesignTokens.Spacing.m)
            .background(
                Capsule().fill(MooreColor.steelRaised)
            )
            .overlay(
                Capsule().strokeBorder(MooreColor.steelHairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(UICopy.homeResumeCta)
    }
}
