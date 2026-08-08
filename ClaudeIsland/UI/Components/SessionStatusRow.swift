//
//  SessionStatusRow.swift
//  ClaudeIsland
//
//  Model, reasoning effort, and context window usage for the active session
//

import SwiftUI

struct SessionStatusRow: View {
    let session: SessionState

    var body: some View {
        HStack(spacing: 6) {
            if let model = session.displayModelName {
                Text(model)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.notchFG.opacity(0.5))
                    .lineLimit(1)
            }

            if let effort = session.displayEffortLevel {
                Text(effort.capitalized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.notchFG.opacity(0.4))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.notchFG.opacity(0.08))
                    )
            }

            Spacer(minLength: 4)

            ContextWindowIndicator(contextWindow: session.displayContextWindow)
        }
    }
}
