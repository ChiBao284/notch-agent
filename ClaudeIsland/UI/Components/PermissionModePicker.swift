//
//  PermissionModePicker.swift
//  ClaudeIsland
//
//  Shows and switches a session's Claude Code permission mode
//

import SwiftUI

/// Shows the session's current Claude Code permission mode and lets the user
/// cycle it mid-session. Bypass Permissions and Don't Ask are omitted — Claude
/// Code only allows entering those at session startup, so no control here
/// could ever reach them.
struct PermissionModePicker: View {
    let session: SessionState
    let sessionMonitor: ClaudeSessionMonitor

    @State private var isSwitching = false
    @State private var isHovered = false

    private var currentMode: ClaudePermissionMode? {
        sessionMonitor.instances.first { $0.sessionId == session.sessionId }?.permissionMode
    }

    var body: some View {
        Menu {
            ForEach(ClaudePermissionMode.cyclable, id: \.self) { mode in
                Button {
                    switchTo(mode)
                } label: {
                    if mode == currentMode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if isSwitching {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: currentMode?.icon ?? "questionmark.circle")
                        .font(.system(size: 10))
                }

                Text(currentMode?.label ?? "—")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(.notchFG.opacity(isHovered ? 0.85 : 0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.notchFG.opacity(isHovered ? 0.08 : 0.05))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isSwitching)
        .onHover { isHovered = $0 }
        .help("Claude Code permission mode")
    }

    private func switchTo(_ mode: ClaudePermissionMode) {
        guard mode != currentMode, !isSwitching else { return }
        isSwitching = true
        Task {
            await PermissionModeSwitcher.switchMode(session: session, to: mode) {
                sessionMonitor.instances.first { $0.sessionId == session.sessionId }?.permissionMode
            }
            await MainActor.run { isSwitching = false }
        }
    }
}
