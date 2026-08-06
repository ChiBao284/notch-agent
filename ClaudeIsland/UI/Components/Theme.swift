//
//  Theme.swift
//  ClaudeIsland
//
//  Adaptive colour palette for the notch UI.
//
//  The UI used to hardcode white-on-black. Every surface now resolves through
//  these colours instead, so the whole island flips with the appearance chosen
//  in Settings (see ThemeManager) without each view knowing about the theme.
//

import AppKit
import SwiftUI

extension Color {
    /// A colour that resolves differently depending on the effective appearance.
    ///
    /// The notch panel's `NSAppearance` is pinned by `ThemeManager`, so these
    /// resolve against the user's chosen theme rather than the system's.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// Convenience for greys that only differ in brightness.
    fileprivate init(lightWhite: CGFloat, darkWhite: CGFloat) {
        self.init(
            light: NSColor(white: lightWhite, alpha: 1),
            dark: NSColor(white: darkWhite, alpha: 1)
        )
    }
}

// MARK: - Notch Palette

extension Color {
    /// Primary foreground. Stands in for the `.white` the UI used to assume, so
    /// `.notchFG.opacity(x)` works for both text and translucent fills.
    static let notchFG = Color(lightWhite: 0.09, darkWhite: 1.0)

    /// Inverse of ``notchFG`` — content drawn on top of a solid `notchFG` fill
    /// (e.g. the label of the "Allow" button).
    static let notchFGInverted = Color(lightWhite: 1.0, darkWhite: 0.0)

    /// The island body fill.
    static let notchPanel = Color(
        light: NSColor(srgbRed: 0.957, green: 0.957, blue: 0.965, alpha: 1),
        dark: .black
    )

    /// Tint for the bars framing the chat view (header and input row).
    static let notchBar = Color(
        light: NSColor(white: 0, alpha: 0.035),
        dark: NSColor(white: 0, alpha: 0.2)
    )

    /// Drop shadow behind the island. Black at 70% would smear the light panel.
    static let notchShadow = Color(
        light: NSColor(white: 0, alpha: 0.22),
        dark: NSColor(white: 0, alpha: 0.7)
    )
}
