//
//  ElapsedTimeLabel.swift
//  ClaudeIsland
//
//  Live "how long has this been running" readout
//

import Combine
import SwiftUI

/// Counts up from `since`, ticking once a second.
///
/// Kept as its own view so the timer only invalidates this label rather than
/// the whole notch on every tick.
struct ElapsedTimeLabel: View {
    let since: Date
    var color: Color = .white.opacity(0.55)

    @State private var now: Date = .distantPast

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(Self.format(now.timeIntervalSince(since)))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(color)
            .monospacedDigit()
            .onAppear { now = Date() }
            .onReceive(ticker) { now = $0 }
    }

    /// `9s`, `1:05`, `1:02:03` — always narrow enough for the collapsed pill.
    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        }
        return "\(seconds)s"
    }
}
