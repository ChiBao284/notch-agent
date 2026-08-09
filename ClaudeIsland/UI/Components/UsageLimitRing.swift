//
//  UsageLimitRing.swift
//  ClaudeIsland
//
//  A small ring showing a 0-100 percentage — reused for plan usage limits
//  (5-hour / weekly) and per-session context window usage
//

import SwiftUI

struct UsageLimitRing: View {
    let percentage: Double?
    let size: CGFloat
    var lineWidth: CGFloat = 1.5
    var helpText: String = ""

    /// Fixed colour for the arc. Nil keeps the threshold shading — green while
    /// there is room, amber as it fills, red near the limit.
    ///
    /// A plan limit is a warning and earns those colours; a context window is
    /// just a gauge, and reads better in one steady tint.
    var tint: Color?

    /// Faint ring behind the arc, so a nearly empty gauge still reads as one.
    var showsTrack: Bool = false

    private var ringColor: Color {
        if let tint { return tint }
        guard let percentage else { return .clear }
        switch percentage {
        case ..<60: return TerminalColors.green
        case ..<85: return TerminalColors.amber
        default: return TerminalColors.red
        }
    }

    var body: some View {
        if let percentage {
            ZStack {
                if showsTrack {
                    Circle()
                        .stroke(Color.notchFG.opacity(0.12), lineWidth: lineWidth)
                }

                Circle()
                    .trim(from: 0, to: CGFloat(min(percentage, 100)) / 100)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
            .help(helpText)
        }
    }
}
