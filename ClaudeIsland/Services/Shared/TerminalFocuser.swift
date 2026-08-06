//
//  TerminalFocuser.swift
//  ClaudeIsland
//
//  Brings the terminal running a Claude Code session to the front
//

import AppKit
import Foundation
import os.log

/// Identity of the app that owns a session's terminal window.
struct TerminalAppInfo: Sendable, Equatable {
    let pid: pid_t
    let name: String
    let bundleId: String?
}

/// Focuses the terminal hosting a Claude Code session.
///
/// yabai gives the most precise result when it is installed (it can raise one
/// specific window), but it is not required: walking the process tree from the
/// Claude PID up to the owning GUI app and activating that works everywhere.
enum TerminalFocuser {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "TerminalFocuser")

    // MARK: - Public API

    /// Focus the terminal for a session. Returns false when no window could be found.
    @discardableResult
    static func focus(session: SessionState) async -> Bool {
        // In tmux, select the pane first — otherwise raising the window shows
        // whichever pane happened to be active.
        if session.isInTmux {
            await selectTmuxPane(for: session)
        }

        if await WindowFinder.shared.isYabaiAvailable() {
            if let pid = session.pid, await YabaiController.shared.focusWindow(forClaudePid: pid) {
                return true
            }
            if await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd) {
                return true
            }
        }

        return await activateOwningApp(of: session)
    }

    /// The app that owns a session's terminal window, if we can identify it.
    static func owningApp(of session: SessionState) async -> TerminalAppInfo? {
        let chain = await ancestorChain(for: session)

        return await MainActor.run {
            guard let app = firstRegularApp(in: chain) else { return nil }
            return TerminalAppInfo(
                pid: app.processIdentifier,
                name: app.localizedName ?? "the terminal",
                bundleId: app.bundleIdentifier
            )
        }
    }

    // MARK: - Tmux

    private static func selectTmuxPane(for session: SessionState) async {
        var target: TmuxTarget?
        if let pid = session.pid {
            target = await TmuxController.shared.findTmuxTarget(forClaudePid: pid)
        }
        if target == nil {
            target = await TmuxController.shared.findTmuxTarget(forWorkingDirectory: session.cwd)
        }
        guard let target else { return }
        _ = await TmuxController.shared.switchToPane(target: target)
    }

    // MARK: - Process Tree

    /// Activate the GUI app that owns the session's process.
    private static func activateOwningApp(of session: SessionState) async -> Bool {
        let chain = await ancestorChain(for: session)

        return await MainActor.run {
            guard let app = firstRegularApp(in: chain) else {
                logger.debug("No owning GUI app found for session")
                return false
            }
            return app.activate(options: .activateAllWindows)
        }
    }

    /// PIDs from the session's process up towards launchd, nearest first.
    ///
    /// Runs off the main actor — it shells out to `ps`, which is slow enough to
    /// hitch the notch animation.
    private static func ancestorChain(for session: SessionState) async -> [pid_t] {
        // Inside tmux the Claude process descends from the tmux *server*, whose
        // parent is launchd — walking up from it never reaches a window. Start
        // from the attached client instead, which does live under a terminal.
        if session.isInTmux {
            let clientChains = await tmuxClientChains(for: session)
            if !clientChains.isEmpty { return clientChains }
        }

        let pid = session.pid
        let tty = session.tty

        return await Task.detached(priority: .userInitiated) {
            let tree = ProcessTreeBuilder.shared.buildTree()

            // Prefer the reported PID; fall back to any process on the session's
            // tty (sessions restored from disk may not carry a PID).
            var start = pid
            if start == nil, let tty {
                start = tree.values.first { $0.tty == tty && $0.command.lowercased().contains("claude") }?.pid
                    ?? tree.values.first { $0.tty == tty }?.pid
            }
            guard var current = start else { return [] }

            var chain: [pid_t] = []
            var depth = 0
            while current > 1 && depth < 25 {
                chain.append(pid_t(current))
                guard let info = tree[current] else { break }
                current = info.ppid
                depth += 1
            }
            return chain
        }.value
    }

    /// Ancestor PIDs of the tmux clients attached to this session's tmux session.
    private static func tmuxClientChains(for session: SessionState) async -> [pid_t] {
        var target: TmuxTarget?
        if let pid = session.pid {
            target = await TmuxController.shared.findTmuxTarget(forClaudePid: pid)
        }
        if target == nil {
            target = await TmuxController.shared.findTmuxTarget(forWorkingDirectory: session.cwd)
        }

        guard let target,
              let tmuxPath = await TmuxPathFinder.shared.getTmuxPath(),
              let output = try? await ProcessExecutor.shared.run(
                  tmuxPath,
                  arguments: ["list-clients", "-t", target.session, "-F", "#{client_pid}"]
              )
        else {
            return []
        }

        let clientPids = output
            .components(separatedBy: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        guard !clientPids.isEmpty else { return [] }

        return await Task.detached(priority: .userInitiated) {
            let tree = ProcessTreeBuilder.shared.buildTree()
            var chain: [pid_t] = []

            for clientPid in clientPids {
                var current = clientPid
                var depth = 0
                while current > 1 && depth < 25 {
                    chain.append(pid_t(current))
                    guard let info = tree[current] else { break }
                    current = info.ppid
                    depth += 1
                }
            }

            return chain
        }.value
    }

    /// First PID in the chain that belongs to an app with a Dock presence.
    @MainActor
    private static func firstRegularApp(in chain: [pid_t]) -> NSRunningApplication? {
        for pid in chain {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if app.activationPolicy == .regular {
                return app
            }
        }
        return nil
    }
}
