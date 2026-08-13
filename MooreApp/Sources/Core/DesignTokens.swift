// Ticket #33 — design tokens, token-level frozen by the visual design system
// resolution (#17, SC-visual-system@1.0.0): athletic-bold register on cold-steel
// neutrals, Liquid Glass in four named tiers, ONE saturated accent hex that never
// gets blurred, rim-light signature. This file is the token source of truth;
// the SwiftUI mapping lives in Views/DesignSystem.swift. Full visual polish is #40.
//
// Foundation-only (no SwiftUI) so it parses/verifies off-Mac.

import Foundation

public enum DesignTokens {

    // MARK: Color — steel neutrals + accent

    public enum Colors {
        /// steel.base — money screen background (opaque)
        public static let steelBase: UInt32 = 0x0A0A0B
        /// steel.raised — elevated surfaces, cards
        public static let steelRaised: UInt32 = 0x1C1C1E
        /// steel.hairline — borders, dividers
        public static let steelHairline: UInt32 = 0x2C2C2E
        /// lime.vivid / lime.ink — the ONE accent hex. On glass surfaces it is
        /// text/icon tint only; never a background fill, never blurred.
        public static let limeVivid: UInt32 = 0xD4FF3F

        /// sRGB components in 0...1 for platform color construction.
        public static func components(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
            (
                red: Double((hex >> 16) & 0xFF) / 255.0,
                green: Double((hex >> 8) & 0xFF) / 255.0,
                blue: Double(hex & 0xFF) / 255.0
            )
        }
    }

    // MARK: Glass tiers (materials applied at the SwiftUI layer)

    /// glass.primary — Tier 1 persistent shell (tab bar, mini-player, Summary container).
    /// glass.secondary — Tiers 2/3/4 sheets, modals, overlays, chips.
    /// Tints are static — never context-reactive.
    public enum GlassTier: String, CaseIterable, Sendable {
        case primary
        case secondary
    }

    // MARK: Typography (system stack only; scale + weight create hierarchy)

    public enum TypographyRole: String, CaseIterable, Sendable {
        /// display.athletic — headlines, screen titles, weight/rep numbers at max size
        case displayAthletic
        /// numeric.mono — set-list digits (weight, reps, rest timer), PR values
        case numericMono
        /// body.standard — descriptions, settings, secondary text
        case bodyStandard
    }

    // MARK: Shape — corner-radius ladder by tier

    public enum Radius {
        /// Tier 1: full-bleed, no rounding
        public static let tier1: Double = 0
        /// Tier 2: system sheet radius (platform default; not a numeric token)
        public static let tier3: Double = 16
        /// Tier 4 / chips: capsule (fully rounded)
        public static let capsule: Double = .greatestFiniteMagnitude
    }

    // MARK: Spacing rhythm (NOT contract-frozen — #17 leaves spacing to the
    // screen blueprint; these are the app's working scale)

    public enum Spacing {
        public static let xs: Double = 4
        public static let s: Double = 8
        public static let m: Double = 12
        public static let l: Double = 16
        public static let xl: Double = 24
        public static let xxl: Double = 32
    }

    // MARK: Motion (exhaustive — the four sanctioned springs/durations)

    public enum Motion {
        /// motion.expand — mini-player ⇄ Active Workout
        public static let expandSeconds: Double = 0.400
        /// motion.morph — rest overlay → Finish panel (the one sanctioned rupture)
        public static let morphSeconds: Double = 0.350
        /// motion.pop — PR toast pop-in
        public static let popSeconds: Double = 0.300
        /// motion.flash — ✓ press feedback
        public static let flashSeconds: Double = 0.080
    }
}
