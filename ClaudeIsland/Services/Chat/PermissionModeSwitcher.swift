//
//  PermissionModeSwitcher.swift
//  ClaudeIsland
//
//  Switches a session's Claude Code permission mode from the notch
//

import Foundation
import os.log

/// Switches a session's permission mode by sending the same Shift+Tab
/// keystroke a user would press, confirming each step against the mode the
/// hook actually reports — never a blind press count, since the cycle's
/// length depends on which optional modes (like `auto`) are enabled for the
/// account.
///
/// `bypassPermissions` and `dontAsk` are deliberately unsupported: Claude Code
/// refuses to enter either one in a session that wasn't started with it
/// enabled, so no amount of cycling from here can ever reach them.
enum PermissionModeSwitcher {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "PermissionMode")

    /// Presses before giving up — comfortably more than the longest possible
    /// cycle (manual, acceptEdits, plan, bypassPermissions, auto).
    private static let maxAttempts = 8

    /// Time given to the hook to report the new mode after each press.
    private static let settleDelayMs: UInt64 = 260

    /// Cycle `session` to `target`. Returns true once `currentMode()` reports
    /// `target`, false if `target` isn't cyclable or the attempt gives up.
    @discardableResult
    static func switchMode(
        session: SessionState,
        to target: ClaudePermissionMode,
        currentMode: @escaping () -> ClaudePermissionMode?
    ) async -> Bool {
        guard ClaudePermissionMode.cyclable.contains(target) else {
            logger.warning("\(target.label, privacy: .public) can't be entered mid-session — ignoring")
            return false
        }
        if currentMode() == target { return true }

        guard let app = await TerminalFocuser.owningApp(of: session) else {
            logger.debug("No owning app found for session — can't send Shift+Tab")
            return false
        }
        guard await TerminalFocuser.focus(session: session) else { return false }

        // Give the activation a moment to land before the first press.
        try? await Task.sleep(for: .milliseconds(220))

        for _ in 0..<maxAttempts {
            guard await MainActor.run(body: { KeystrokeTyper.pressShiftTab(intoPid: app.pid) }) else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(settleDelayMs))
            if currentMode() == target { return true }
        }

        logger.debug("Gave up cycling to \(target.label, privacy: .public) after \(maxAttempts) presses")
        return false
    }
}
