//
//  SessionMetaLine.swift
//  ClaudeIsland
//
//  Project / branch / timing strip shared by the session list and the chat header
//

import Combine
import SwiftUI

/// `📁 project  ⑂ branch  · 2 minutes ago`
///
/// Shared so the list row and the chat header cannot drift apart.
struct SessionMetaLine: View {
    let session: SessionState
    /// Whether to append the timing readout (running clock, or how long ago the
    /// turn finished). The collapsed notch shows its own clock, so the list row
    /// leaves this off.
    var showsTiming: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(session.projectName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
                    .font(.system(size: 9))
            }
            .foregroundColor(.notchFG.opacity(0.45))

            if let branch = session.gitBranch {
                Label {
                    Text(branch)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                }
                .foregroundColor(TerminalColors.prompt.opacity(0.8))
            }

            if showsTiming {
                SessionTimingLabel(session: session)
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Timing

/// Live clock while a turn runs, otherwise how long ago it finished.
private struct SessionTimingLabel: View {
    let session: SessionState

    var body: some View {
        if session.phase.isRunningTurn, let startedAt = session.turnStartedAt {
            // Reuses the notch's clock so both count in step, at 1s resolution.
            Label {
                ElapsedTimeLabel(since: startedAt, color: TerminalColors.prompt.opacity(0.75))
            } icon: {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundColor(TerminalColors.prompt.opacity(0.75))
            }
        } else if let endedAt = session.turnEndedAt {
            FinishedAgoLabel(endedAt: endedAt)
        }
    }
}

/// "2 minutes ago" — only needs minute resolution, so it ticks slowly.
private struct FinishedAgoLabel: View {
    let endedAt: Date

    @State private var now: Date = .distantPast
    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        Label {
            Text(Self.relative.localizedString(for: endedAt, relativeTo: max(now, endedAt)))
                .font(.system(size: 10, weight: .medium))
        } icon: {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 9))
        }
        .foregroundColor(.notchFG.opacity(0.4))
        .onAppear { now = Date() }
        .onReceive(ticker) { now = $0 }
    }
}
