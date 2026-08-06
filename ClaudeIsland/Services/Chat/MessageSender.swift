//
//  MessageSender.swift
//  ClaudeIsland
//
//  Delivers a message typed in the notch to a running Claude Code session
//

import AppKit
import Foundation
import os.log

// MARK: - Scriptable Terminals

/// Terminals that expose their tabs to AppleScript, letting us deliver a
/// message to one specific tab without disturbing window focus.
enum ScriptableTerminal: String, Sendable, Equatable {
    case appleTerminal = "com.apple.Terminal"
    case iTerm2 = "com.googlecode.iterm2"

    var displayName: String {
        switch self {
        case .appleTerminal: return "Terminal"
        case .iTerm2: return "iTerm2"
        }
    }

    init?(bundleIdentifier: String?) {
        guard let bundleIdentifier,
              let match = ScriptableTerminal(rawValue: bundleIdentifier) else { return nil }
        self = match
    }
}

// MARK: - Channel

/// How a typed message can reach a session.
enum MessageChannel: Equatable, Sendable {
    /// Not worked out yet. Treated as sendable so the composer is live straight
    /// away — `send` resolves the channel itself, so an early Return still lands.
    case resolving

    /// `tmux send-keys` — delivered without touching window focus. Best case.
    case tmux(TmuxTarget)

    /// Scripted straight into the owning terminal tab. Also focus-free.
    case terminalScript(terminal: ScriptableTerminal, tty: String)

    /// Raised, then typed as keystrokes. Steals focus, needs Accessibility.
    ///
    /// `requiresTextFieldFocus` is set for GUI hosts (Claude Desktop), where the
    /// keystrokes would otherwise trigger app shortcuts if no field has focus.
    case keystrokes(appName: String, pid: pid_t, requiresTextFieldFocus: Bool)

    case unavailable(Reason)

    enum Reason: Equatable, Sendable {
        /// No running terminal could be matched to the session.
        case noTerminal
        /// A terminal was found, but typing into it needs Accessibility.
        case needsAccessibility(appName: String)
        /// The session runs in an editor's embedded terminal, where keystrokes
        /// could land in a source file instead of the shell.
        case embeddedTerminal(appName: String)
    }

    var canSend: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// Whether sending will pull the user away from the notch.
    var stealsFocus: Bool {
        if case .keystrokes = self { return true }
        return false
    }

    /// Actionable explanation for a send that did not land.
    var failureExplanation: String {
        switch self {
        case .unavailable(.needsAccessibility(let appName)):
            return "Grant Accessibility to Vibe Notch to type into \(appName)"
        case .unavailable(.embeddedTerminal(let appName)):
            return "Can't type into \(appName) safely — run Claude Code in tmux or Terminal"
        case .unavailable(.noTerminal):
            return "No running terminal found for this session"
        case .keystrokes(let appName, _, let needsField):
            return needsField
                ? "Put the cursor in \(appName)'s message box, then send again"
                : "Couldn't type into \(appName) — is it still running?"
        case .tmux, .terminalScript, .resolving:
            return "Couldn't deliver the message — the session may have ended"
        }
    }

    /// Placeholder for the composer.
    var placeholder: String {
        switch self {
        case .resolving, .tmux, .terminalScript:
            return "Message Claude..."
        case .keystrokes(let appName, _, let needsField):
            return needsField
                ? "Message Claude (types into \(appName)'s active session)..."
                : "Message Claude (types into \(appName))..."
        case .unavailable(.needsAccessibility(let appName)):
            return "Enable Accessibility to message \(appName)"
        case .unavailable(.embeddedTerminal(let appName)):
            return "Run Claude Code in tmux to message from \(appName)"
        case .unavailable(.noTerminal):
            return "No running terminal found for this session"
        }
    }
}

// MARK: - Sender

/// Resolves how to reach a session and delivers messages to it.
enum MessageSender {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "MessageSender")

    // MARK: - Resolution

    /// Work out the best delivery channel for a session.
    ///
    /// Cheap and side-effect free — in particular it never sends an Apple Event,
    /// so merely opening a chat cannot trigger a permission prompt.
    static func resolveChannel(for session: SessionState) async -> MessageChannel {
        if session.isInTmux, let tty = session.tty, let target = await tmuxTarget(forTty: tty) {
            return .tmux(target)
        }

        guard let app = await TerminalFocuser.owningApp(of: session) else {
            return .unavailable(.noTerminal)
        }

        // Scriptable terminals can be targeted by tty, so the message lands in
        // the right tab no matter what the user is looking at.
        if let terminal = ScriptableTerminal(bundleIdentifier: app.bundleId), let tty = session.tty {
            return .terminalScript(terminal: terminal, tty: tty)
        }

        // Everything else means synthetic keystrokes, which go to whatever is
        // focused. Refuse for editors, where that could be a source file.
        guard TerminalAppRegistry.acceptsKeystrokeDelivery(bundleId: app.bundleId) else {
            return .unavailable(.embeddedTerminal(appName: app.name))
        }

        guard await MainActor.run(body: { KeystrokeTyper.isPermitted }) else {
            return .unavailable(.needsAccessibility(appName: app.name))
        }

        // A session with no controlling terminal is hosted by a GUI app — Claude
        // Code inside Claude Desktop reports tty `??`. Its composer is the input,
        // so typing still works, but we must confirm a text field really has
        // focus first or the keystrokes would fire app shortcuts instead.
        return .keystrokes(
            appName: app.name,
            pid: app.pid,
            requiresTextFieldFocus: session.tty == nil
        )
    }

    // MARK: - Sending

    /// Deliver `text` to `session`. Resolves the channel fresh so a session that
    /// moved (or a permission that was just granted) is picked up.
    @discardableResult
    static func send(_ text: String, to session: SessionState) async -> Bool {
        let message = normalize(text)
        guard !message.isEmpty else { return false }

        let channel = await resolveChannel(for: session)

        switch channel {
        case .resolving:
            // resolveChannel never returns this — it is the composer's initial state.
            return false

        case .tmux(let target):
            return await ToolApprovalHandler.shared.sendMessage(message, to: target)

        case .terminalScript(let terminal, let tty):
            if await sendViaScript(message, terminal: terminal, tty: tty) {
                return true
            }
            // Scripting can fail because Automation was denied. Fall through to
            // keystrokes so the user still gets their message delivered.
            logger.debug("Script delivery failed, trying keystrokes")
            return await sendViaKeystrokes(message, session: session)

        case .keystrokes:
            return await sendViaKeystrokes(message, session: session)

        case .unavailable(let reason):
            logger.debug("No channel available: \(String(describing: reason), privacy: .public)")
            return false
        }
    }

    // MARK: - tmux

    private static func tmuxTarget(forTty tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return nil }

        guard let output = try? await ProcessExecutor.shared.run(
            tmuxPath,
            arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
        ) else {
            return nil
        }

        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: " ")
            guard parts.count >= 2 else { continue }
            guard sameTty(parts[1], tty) else { continue }
            return TmuxTarget(from: parts[0])
        }

        return nil
    }

    // MARK: - AppleScript

    private static func sendViaScript(_ message: String, terminal: ScriptableTerminal, tty: String) async -> Bool {
        let script = scriptSource(for: terminal, tty: tty, message: message)

        switch await AppleScriptRunner.run(script) {
        case .success(let result):
            if result == "ok" { return true }
            logger.debug("\(terminal.displayName, privacy: .public) has no tab on tty \(tty, privacy: .public)")
            return false
        case .failure(let error):
            if error.isPermissionDenied {
                logger.notice("Automation permission denied for \(terminal.displayName, privacy: .public)")
            }
            return false
        }
    }

    private static func scriptSource(for terminal: ScriptableTerminal, tty: String, message: String) -> String {
        let escapedMessage = AppleScriptRunner.escape(message)
        // Session ttys are stored without the /dev prefix; match on the suffix so
        // either form works.
        let escapedTty = AppleScriptRunner.escape(deviceName(of: tty))

        switch terminal {
        case .appleTerminal:
            return """
            tell application id "com.apple.Terminal"
                set matched to missing value
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if (tty of t) ends with "\(escapedTty)" then set matched to t
                        end try
                    end repeat
                end repeat
                if matched is missing value then return "no-tty"
                do script "\(escapedMessage)" in matched
                return "ok"
            end tell
            """

        case .iTerm2:
            return """
            tell application id "com.googlecode.iterm2"
                set matched to missing value
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                if (tty of s) ends with "\(escapedTty)" then set matched to s
                            end try
                        end repeat
                    end repeat
                end repeat
                if matched is missing value then return "no-tty"
                tell matched to write text "\(escapedMessage)"
                return "ok"
            end tell
            """
        }
    }

    // MARK: - Keystrokes

    private static func sendViaKeystrokes(_ message: String, session: SessionState) async -> Bool {
        guard await MainActor.run(body: { KeystrokeTyper.isPermitted }) else { return false }
        guard let app = await TerminalFocuser.owningApp(of: session) else { return false }

        // Defence in depth: never type into an editor, whatever route got us here.
        guard TerminalAppRegistry.acceptsKeystrokeDelivery(bundleId: app.bundleId) else {
            logger.notice("Refusing keystroke delivery into an editor")
            return false
        }

        // Keystrokes go to the focused window, so the terminal has to come
        // forward first — including the right tmux pane.
        guard await TerminalFocuser.focus(session: session) else { return false }

        // Give the activation a moment to land before typing.
        try? await Task.sleep(for: .milliseconds(220))

        return await MainActor.run {
            KeystrokeTyper.type(
                message,
                intoPid: app.pid,
                requiresTextFieldFocus: session.tty == nil
            )
        }
    }

    // MARK: - Helpers

    /// Collapse newlines to spaces. The composer is single-line, so a pasted
    /// multi-line block would otherwise submit as several separate prompts.
    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `ttys003` for both `ttys003` and `/dev/ttys003`.
    private static func deviceName(of tty: String) -> String {
        tty.replacingOccurrences(of: "/dev/", with: "")
    }

    private static func sameTty(_ lhs: String, _ rhs: String) -> Bool {
        deviceName(of: lhs) == deviceName(of: rhs)
    }
}
