// Ticket #35 — the non-modal stall banner (SC-progression BR-013/BR-018).
// One inline line at the top of an exercise group: copy + tap-to-apply
// Deload/Hold/Ignore + dismiss. NEVER a modal, NEVER blocks the per-set ✓ —
// it renders as a plain list row and every gesture is an explicit tap.
//
// Thin view: the firing condition, copy, and choice semantics live in
// ProgressionModel (Foundation-only); this file only lays them out.

import SwiftUI
import MooreProgression

struct StallBannerView: View {
    let banner: StallBanner
    let onChoice: (StallAction) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            // progression.banner.stall — "Looks stalled on {name} — {n} sessions
            // short of target."
            Text(banner.copy)
                .font(MooreFont.body(.subheadline))
                .foregroundStyle(MooreColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignTokens.Spacing.s) {
                // progression.banner.deloadCta — BR-013: renders only when a
                // weight exists for the pair (bodyweight pairs get Hold/Ignore).
                if banner.deloadAvailable {
                    Button(UICopy.progressionDeloadCta) {
                        onChoice(.deload)
                    }
                    .buttonStyle(MooreSecondaryButtonStyle())
                }
                // progression.banner.holdCta
                Button(UICopy.progressionHoldCta) {
                    onChoice(.hold)
                }
                .buttonStyle(MooreSecondaryButtonStyle())
                // progression.banner.ignoreCta
                Button(UICopy.progressionIgnoreCta) {
                    onChoice(.ignore)
                }
                .buttonStyle(MooreSecondaryButtonStyle())

                Spacer(minLength: 0)

                // Dismissal chooses nothing — the banner re-appears next session.
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(MooreColor.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(UICopy.editorCancel)
            }
        }
        .padding(DesignTokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.tier3)
                .fill(MooreColor.steelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.tier3)
                .strokeBorder(MooreColor.steelHairline, lineWidth: 1)
        )
    }
}
