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

    private var ringColor: Color {
        guard let percentage else { return .clear }
        switch percentage {
        case ..<60: return TerminalColors.green
        case ..<85: return TerminalColors.amber
        default: return TerminalColors.red
        }
    }

    var body: some View {
        if let percentage {
            Circle()
                .trim(from: 0, to: CGFloat(min(percentage, 100)) / 100)
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: size, height: size)
                .help(helpText)
        }
    }
}
