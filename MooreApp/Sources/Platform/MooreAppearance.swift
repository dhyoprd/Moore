// Ticket #40 — UIKit appearance for the system bars (SC-visual-system,
// Tier 1 persistent shell). The tab bar rides glass.primary: a steel-tinted
// translucent chrome (static tint — never context-reactive) with the
// rim-light signature as the 1px hairline top divider, lime ink on the
// selected item, steel-secondary ink elsewhere. SwiftUI's `.tint` cannot
// reach the UITabBar chrome itself, so the appearance proxy is the seam.
//
// Mac-build-only: imports UIKit.

import UIKit

enum MooreAppearance {

    /// Call once, before the first frame (MooreApp.init).
    static func configure() {
        configureTabBar()
    }

    // MARK: Tab bar — glass.primary tier

    private static func configureTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()

        // glass.primary static tint: steel base, translucent.
        appearance.backgroundColor = color(DesignTokens.Colors.steelBase).withAlphaComponent(0.85)

        // Rim-light signature: the 1px top edge reads as a hairline highlight
        // against the content above it.
        appearance.shadowColor = color(DesignTokens.Colors.steelHairline)

        // Lime ink is foreground-only (never a fill on glass): selected items
        // tint lime; unselected ride steel-secondary.
        let lime = color(DesignTokens.Colors.limeVivid)
        let secondary = UIColor(white: 1.0, alpha: 0.6)

        let item = appearance.stackedLayoutItem
        item.selectedStateConfiguration.iconColor = lime
        item.selectedStateConfiguration.titleTextAttributes = [.foregroundColor: lime]
        item.normalStateConfiguration.iconColor = secondary
        item.normalStateConfiguration.titleTextAttributes = [.foregroundColor: secondary]

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    // MARK: Token bridge

    private static func color(_ hex: UInt32) -> UIColor {
        let components = DesignTokens.Colors.components(hex)
        return UIColor(red: components.red, green: components.green, blue: components.blue, alpha: 1)
    }
}
