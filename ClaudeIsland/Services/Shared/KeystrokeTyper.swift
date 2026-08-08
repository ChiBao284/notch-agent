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

        if requiresTextFieldFocus && !focusedElementAcceptsText() {
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

    /// Whether the system-wide focused element would accept typed text.
    ///
    /// Retries briefly: a Chromium/Electron host (e.g. Claude Desktop) only
    /// finishes wiring up its accessibility tree after the first AX query
    /// against it, so a check made right after activating the app can come
    /// back empty even though the composer genuinely has focus.
    private static func focusedElementAcceptsText() -> Bool {
        for attempt in 0..<3 {
            if focusedElementAcceptsTextOnce() { return true }
            if attempt < 2 { usleep(150_000) }
        }
        return false
    }

    private static func focusedElementAcceptsTextOnce() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            return false
        }

        let element = focusedValue as! AXUIElement

        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String,
           role == kAXTextFieldRole as String || role == kAXTextAreaRole as String {
            return true
        }

        // Electron composers frequently expose themselves as a generic element
        // with a writable value rather than a text role — accept those too.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
            return settable.boolValue
        }

        return false
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
