// Ticket #33 — SwiftUI mapping of the frozen design tokens (DesignTokens.swift).
// SC-visual-system@1.0.0: steel neutrals, ONE lime accent hex, glass tiers as
// system materials with static tints, athletic-bold display + mono numerics.
// Full visual polish (rim light, spacing rhythm, motion wiring) lands in #40.

import SwiftUI

// MARK: - Colors

enum MooreColor {
    static let steelBase = Color(hex: DesignTokens.Colors.steelBase)
    static let steelRaised = Color(hex: DesignTokens.Colors.steelRaised)
    static let steelHairline = Color(hex: DesignTokens.Colors.steelHairline)
    /// lime.vivid / lime.ink — the one accent. On glass it is ink only (never fill).
    static let lime = Color(hex: DesignTokens.Colors.limeVivid)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.6)
}

extension Color {
    init(hex: UInt32) {
        let c = DesignTokens.Colors.components(hex)
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
    }
}

// MARK: - Typography (system stack only; hierarchy via scale + weight)

enum MooreFont {
    /// display.athletic — bold system (SF Pro) for headlines/titles/big numbers.
    static func display(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .default, weight: .bold)
    }
    /// numeric.mono — monospaced digits for weights/reps/stats.
    static func numeric(_ style: Font.TextStyle = .body) -> Font {
        .system(style, design: .monospaced)
    }
    /// body.standard — regular system for descriptions/secondary text.
    static func body(_ style: Font.TextStyle = .body) -> Font {
        .system(style, design: .default)
    }
}

// MARK: - Surfaces

/// steel.raised card with hairline border; Tier 3 radius on steel surfaces
/// reads as the raised tier (no glass on the money screen; cards are steel).
struct MooreCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(DesignTokens.Spacing.l)
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

extension View {
    func mooreCard() -> some View { modifier(MooreCard()) }
}

// MARK: - Buttons

/// Primary CTA — lime fill with black ink (opaque steel context, so lime may fill).
struct MoorePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MooreFont.display(.body))
            .foregroundStyle(.black)
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.vertical, DesignTokens.Spacing.m)
            .background(Capsule().fill(MooreColor.lime))
            .opacity(configuration.isPressed ? 0.7 : 1)   // motion.flash territory
    }
}

/// Secondary/toolbar CTA — lime ink on glass (tint only, never fill).
struct MooreSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MooreFont.display(.subheadline))
            .foregroundStyle(MooreColor.lime)
            .padding(.horizontal, DesignTokens.Spacing.m)
            .padding(.vertical, DesignTokens.Spacing.s)
            .background(Capsule().strokeBorder(MooreColor.lime.opacity(0.6), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Streak chip / tags — capsule, lime ink, hairline border (chip tier = capsule).
struct MooreChip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(MooreFont.display(.footnote))
            .foregroundStyle(MooreColor.lime)
            .padding(.horizontal, DesignTokens.Spacing.m)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(Capsule().fill(MooreColor.steelRaised))
            .overlay(Capsule().strokeBorder(MooreColor.steelHairline, lineWidth: 1))
    }
}

extension View {
    func mooreChip() -> some View { modifier(MooreChip()) }
}

// MARK: - Celebration (SC-prs #36 — the lime accent moments)

/// The celebration accent moment (SC-visual-system: the ONE lime accent hex,
/// never blurred): in-session PR toasts (SC-cues §3a `pr.toast`) and Summary
/// PR cards/banner (`pr.cards`) share this surface — steel-raised, lime
/// hairline, lime ink. Motion is motion.pop (DesignTokens.Motion.popSeconds),
/// applied by the presenting screen. Full visual polish lands in #40.
struct MoorePRCelebration: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.vertical, DesignTokens.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.tier3)
                    .fill(MooreColor.steelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.tier3)
                    .strokeBorder(MooreColor.lime.opacity(0.6), lineWidth: 1)
            )
    }
}

extension View {
    func moorePRCelebration() -> some View { modifier(MoorePRCelebration()) }
}
