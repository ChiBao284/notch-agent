//
//  KeystrokeTyper.swift
//  ClaudeIsland
//
//  Types text into the frontmost app via synthetic key events
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os.log

/// Types text as synthetic keystrokes — the last-resort delivery path for
/// terminals that offer neither tmux nor AppleScript.
///
/// Keystrokes land wherever focus currently is, so every call is guarded on the
/// intended app actually being frontmost. Typing a message into the wrong window
/// is far worse than failing to send it.
@MainActor
enum KeystrokeTyper {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "Keystrokes")

    /// Return / Enter.
    private static let returnKeyCode: CGKeyCode = 36

    /// Tab — posted with the Shift flag to cycle Claude Code's permission mode.
    private static let tabKeyCode: CGKeyCode = 48

    /// Longer payloads on a single event get truncated by the window server.
    private static let chunkSize = 16

    static var isPermitted: Bool {
        AXIsProcessTrusted()
    }

    /// Press Shift+Tab — the same keybinding a user presses to cycle Claude
    /// Code's permission mode — but only if `pid` owns the frontmost app.
    static func pressShiftTab(intoPid pid: pid_t) -> Bool {
        guard isPermitted else {
            logger.debug("Accessibility permission not granted")
            return false
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            logger.warning("Refusing to send Shift+Tab: target app is not frontmost")
            return false
        }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: tabKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: tabKeyCode, keyDown: false) else {
            return false
        }

        down.flags = .maskShift
        up.flags = .maskShift
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Type `text`, then press Return unless `pressReturn` is false — but only
    /// if `pid` owns the frontmost app.
    ///
    /// Set `requiresTextFieldFocus` for GUI hosts such as Claude Desktop: a shell
    /// swallows anything you type, but an app window turns stray letters into
    /// keyboard shortcuts, so there we insist a text field really has focus.
    static func type(_ text: String, intoPid pid: pid_t, requiresTextFieldFocus: Bool = false, pressReturn: Bool = true) -> Bool {
        guard isPermitted else {
            logger.debug("Accessibility permission not granted")
            return false
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            logger.warning("Refusing to type: target app is not frontmost")
            return false
        }

        if requiresTextFieldFocus && !focusedElementAcceptsText(pid: pid) {
            logger.warning("Refusing to type: no text field has focus")
            return false
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            guard post(Array(units[index..<end]), source: source) else { return false }
            index = end
        }

        return pressReturn ? postReturn(source: source) : true
    }

    // MARK: - Focus Check

    /// Total time to give a text field to take focus before giving up.
    ///
    /// A Chromium/Electron host (e.g. Claude Desktop) finishes wiring up its
    /// accessibility tree some indeterminate time after activation — cold
    /// activations (app was backgrounded, or its window needed restoring) have
    /// been observed to land the composer's focus noticeably later than a
    /// warm one. The budget is generous because it only costs time on the
    /// failure path: a focused composer is normally detected on one of the
    /// first couple of polls, well under this ceiling.
    private static let focusPollBudget: TimeInterval = 1.5
    private static let focusPollInterval: useconds_t = 100_000

    /// Whether a focused element that would accept typed text can be found,
    /// polling until `focusPollBudget` elapses.
    ///
    /// Checks two sources each pass: the system-wide focused element (the
    /// common case), and the target app's own idea of what it focused — the
    /// two can briefly disagree right after activation, with the app's
    /// internal state sometimes ahead of what the system-wide element reports.
    private static func focusedElementAcceptsText(pid: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(focusPollBudget)
        var lastSeenRole: String?

        repeat {
            let (accepts, role) = focusedElementAcceptsTextOnce(pid: pid)
            if accepts { return true }
            lastSeenRole = role ?? lastSeenRole
            usleep(focusPollInterval)
        } while Date() < deadline

        // Not proof of what the composer's real shape is — only of whatever
        // last happened to hold focus while we were looking — but it turns
        // the next occurrence of this failure into a concrete lead instead of
        // another blind guess.
        logger.warning("No text field took focus within \(Self.focusPollBudget, format: .fixed(precision: 1))s — last focused role seen: \(lastSeenRole ?? "none", privacy: .public)")
        return false
    }

    private static func focusedElementAcceptsTextOnce(pid: pid_t) -> (accepts: Bool, role: String?) {
        let systemWide = describeFocus(of: AXUIElementCreateSystemWide())
        if systemWide?.accepts == true { return systemWide! }

        let appLevel = describeFocus(of: AXUIElementCreateApplication(pid))
        if appLevel?.accepts == true { return appLevel! }

        return (false, appLevel?.role ?? systemWide?.role)
    }

    /// `element`'s focused descendant: whether it would accept typed text —
    /// either a proper text role, or (Electron's frequent shape) a generic
    /// element with a settable value — and its role, for diagnostics. Nil when
    /// `element` reports no focused descendant at all.
    private static func describeFocus(of element: AXUIElement) -> (accepts: Bool, role: String?)? {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            return nil
        }

        let focused = focusedValue as! AXUIElement

        var roleValue: CFTypeRef?
        let role = (AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleValue) == .success)
            ? roleValue as? String
            : nil

        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String {
            return (true, role)
        }

        // Electron composers frequently expose themselves as a generic element
        // with a writable value rather than a text role — accept those too.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return (true, role)
        }

        return (false, role)
    }

    // MARK: - Event Posting

    private static func post(_ units: [UniChar], source: CGEventSource) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }

        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func postReturn(source: CGEventSource) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: false) else {
            return false
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
