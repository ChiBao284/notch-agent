//
//  ContextWindowIndicator.swift
//  ClaudeIsland
//
//  Shows how much of the context window the session is currently using
//

import SwiftUI

struct ContextWindowIndicator: View {
    let contextWindow: ContextWindowInfo?

    private var fraction: Double {
        guard let pct = contextWindow?.usedPercentage else { return 0 }
        return min(max(pct, 0), 100) / 100
    }

    private var percent: Int {
        Int((fraction * 100).rounded())
    }

    private var barColor: Color {
        switch fraction {
        case ..<0.6: return TerminalColors.green
        case ..<0.85: return TerminalColors.amber
        default: return TerminalColors.red
        }
    }

    var body: some View {
        if let contextWindow, contextWindow.usedPercentage != nil {
            HStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.notchFG.opacity(0.12))
                        Capsule()
                            .fill(barColor)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(width: 28, height: 4)

                Text("\(percent)%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(barColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.notchFG.opacity(0.05))
            )
            .help("Context window: \(contextWindow.formatted) tokens (\(percent)%)")
        }
    }
}
