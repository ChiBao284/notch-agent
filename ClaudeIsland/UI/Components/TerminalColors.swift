//
//  TerminalColors.swift
//  ClaudeIsland
//
//  Color palette for terminal-style UI
//
//  Accents carry a darker light-mode variant — the bright terminal greens and
//  ambers wash out against a light panel.
//

import AppKit
import SwiftUI

struct TerminalColors {
    static let green = Color(
        light: NSColor(srgbRed: 0.16, green: 0.50, blue: 0.24, alpha: 1),
        dark: NSColor(srgbRed: 0.4, green: 0.75, blue: 0.45, alpha: 1)
    )
    static let amber = Color(
        light: NSColor(srgbRed: 0.70, green: 0.45, blue: 0.0, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.7, blue: 0.0, alpha: 1)
    )
    static let red = Color(
        light: NSColor(srgbRed: 0.78, green: 0.16, blue: 0.16, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.3, blue: 0.3, alpha: 1)
    )
    static let cyan = Color(
        light: NSColor(srgbRed: 0.0, green: 0.45, blue: 0.48, alpha: 1),
        dark: NSColor(srgbRed: 0.0, green: 0.8, blue: 0.8, alpha: 1)
    )
    static let blue = Color(
        light: NSColor(srgbRed: 0.13, green: 0.36, blue: 0.82, alpha: 1),
        dark: NSColor(srgbRed: 0.4, green: 0.6, blue: 1.0, alpha: 1)
    )
    static let magenta = Color(
        light: NSColor(srgbRed: 0.58, green: 0.20, blue: 0.62, alpha: 1),
        dark: NSColor(srgbRed: 0.8, green: 0.4, blue: 0.8, alpha: 1)
    )

    /// Claude's signature orange (#d97857), nudged darker for light mode.
    static let prompt = Color(
        light: NSColor(srgbRed: 0.74, green: 0.34, blue: 0.20, alpha: 1),
        dark: NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    )

    /// Alias for ``prompt`` — used where the colour reads as branding rather
    /// than as a terminal prompt.
    static let claudeOrange = prompt

    static let dim = Color.notchFG.opacity(0.4)
    static let dimmer = Color.notchFG.opacity(0.2)
    static let background = Color.notchFG.opacity(0.05)
    static let backgroundHover = Color.notchFG.opacity(0.1)
}

/// Fixed-brightness accents for content drawn on the collapsed notch pill,
/// which stays black in every theme so it blends with the hardware notch.
struct PillColors {
    static let orange = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let green = Color(red: 0.4, green: 0.75, blue: 0.45)
}
