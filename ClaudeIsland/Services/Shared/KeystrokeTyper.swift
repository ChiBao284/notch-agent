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

    /// Longer payloads on a single event get truncated by the window server.
    private static let chunkSize = 16

    static var isPermitted: Bool {
        AXIsProcessTrusted()
    }

    /// Type `text` then press Return, but only if `pid` owns the frontmost app.
    ///
    /// Set `requiresTextFieldFocus` for GUI hosts such as Claude Desktop: a shell
    /// swallows anything you type, but an app window turns stray letters into
    /// keyboard shortcuts, so there we insist a text field really has focus.
    static func type(_ text: String, intoPid pid: pid_t, requiresTextFieldFocus: Bool = false) -> Bool {
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

        return postReturn(source: source)
    }

    // MARK: - Focus Check

    /// Whether the system-wide focused element would accept typed text.
    private static func focusedElementAcceptsText() -> Bool {
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
