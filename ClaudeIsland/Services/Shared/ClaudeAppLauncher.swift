//
//  ClaudeAppLauncher.swift
//  ClaudeIsland
//
//  Brings Claude back to the front when the notch icon is clicked
//

import AppKit
import ApplicationServices
import Foundation
import os.log

/// What the launcher surfaced.
enum ClaudeTarget: Equatable {
    case desktop
    case terminal
}

/// Reopens Claude from the notch.
///
/// Claude Desktop wins when it is installed — that is what most people mean by
/// "Claude". Without it, we surface the terminal running Claude Code instead.
@MainActor
final class ClaudeAppLauncher {
    static let shared = ClaudeAppLauncher()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "ClaudeLauncher")

    /// Bundle identifiers Claude Desktop has shipped under.
    private static let desktopBundleIds = [
        "com.anthropic.claudefordesktop",
        "com.anthropic.claude"
    ]

    /// Cached install location. The notch header re-renders on animation timers,
    /// so `actionHint` must not hit Launch Services on every frame.
    private var cachedDesktopURL: URL?
    private var didResolveDesktopURL = false

    private init() {
        // A Claude Desktop install (or removal) between launches should be picked
        // up without restarting the notch.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.invalidateDesktopURL() }
        }
    }

    // MARK: - Discovery

    /// Where Claude Desktop is installed, if it is.
    var claudeDesktopURL: URL? {
        if didResolveDesktopURL { return cachedDesktopURL }

        cachedDesktopURL = Self.desktopBundleIds.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
        didResolveDesktopURL = true
        return cachedDesktopURL
    }

    var isClaudeDesktopInstalled: Bool {
        claudeDesktopURL != nil
    }

    private func invalidateDesktopURL() {
        didResolveDesktopURL = false
    }

    /// Tooltip text describing what a click will do.
    var actionHint: String {
        isClaudeDesktopInstalled ? "Open Claude Desktop" : "Go to the Claude Code terminal"
    }

    private var runningDesktopApps: [NSRunningApplication] {
        Self.desktopBundleIds.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }
    }

    // MARK: - Actions

    /// Reopen Claude. Prefers Claude Desktop, falling back to the terminal
    /// running `session`. Returns what was surfaced, or nil if nothing was.
    @discardableResult
    func openClaude(fallbackSession session: SessionState?) async -> ClaudeTarget? {
        if await openClaudeDesktop() {
            return .desktop
        }

        if let session, await TerminalFocuser.focus(session: session) {
            return .terminal
        }

        Self.logger.debug("Nothing to surface: Claude Desktop unavailable and no session terminal found")
        return nil
    }

    /// Activate Claude Desktop, restoring a window if the user closed or
    /// minimized it. Returns false when Claude Desktop isn't installed.
    @discardableResult
    func openClaudeDesktop() async -> Bool {
        guard let url = claudeDesktopURL else { return false }

        // Activating an app does not restore windows minimized to the Dock,
        // so un-minimize them first.
        for app in runningDesktopApps {
            app.unhide()
            deminiaturizeWindows(ofPid: app.processIdentifier)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Reuse the running instance — this delivers a reopen event, which is
        // what makes Claude Desktop re-create a window the user closed.
        configuration.createsNewApplicationInstance = false

        do {
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            app.activate(options: .activateAllWindows)
            return true
        } catch {
            Self.logger.error("Failed to open Claude Desktop: \(error.localizedDescription, privacy: .public)")
            // Last resort: raise whatever instance is already running.
            if let app = runningDesktopApps.first {
                return app.activate(options: .activateAllWindows)
            }
            return false
        }
    }

    // MARK: - Window Restoration

    /// Un-minimize an app's windows via the accessibility API.
    ///
    /// No-op without Accessibility permission — activation alone still helps in
    /// the common case where the window is merely behind other windows.
    private func deminiaturizeWindows(ofPid pid: pid_t) {
        guard AXIsProcessTrusted() else { return }

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return
        }

        for window in windows {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }
}
