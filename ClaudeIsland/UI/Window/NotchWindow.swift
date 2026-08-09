//
//  NotchWindow.swift
//  ClaudeIsland
//
//  Transparent window that overlays the notch area
//  Following NotchDrop's approach: window ignores mouse events,
//  we use global event monitors to detect clicks/hovers
//

import AppKit

// Use NSPanel subclass for non-activating behavior
class NotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Floating panel behavior
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        // Transparent configuration
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false

        // CRITICAL: Prevent window from moving during space switches
        isMovable = false

        // Window behavior - stays on all spaces, above menu bar
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        // Above the menu bar
        level = .mainMenu + 3

        // Enable tooltips even when app is inactive (needed for panel windows)
        allowsToolTipsWhenApplicationIsInactive = true

        // CRITICAL: Window ignores ALL mouse events
        // This allows clicks to pass through to the menu bar
        // We use global event monitors to detect hover/clicks on the notch area
        ignoresMouseEvents = true

        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Click-through for areas outside the panel content

    /// Whether the button currently held down was pressed on one of our views.
    ///
    /// A press that starts inside the panel and is released outside still has
    /// its mouse-up delivered here. Passing that up-event through instead of to
    /// the view leaves AppKit holding a tracking session that never ends — the
    /// cursor keeps its drag state and the panel stops responding — and the
    /// `ignoresMouseEvents` flag set on the way out is only ever cleared by a
    /// change of notch status, so an open panel stays click-through.
    private var isTrackingPressInsidePanel = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            if passThroughIfNoViewWants(event) { return }
            isTrackingPressInsidePanel = true

        case .leftMouseUp, .rightMouseUp:
            // Close the tracking session its mouse-down opened, wherever the
            // button happened to come back up.
            if isTrackingPressInsidePanel {
                isTrackingPressInsidePanel = false
                break
            }
            if passThroughIfNoViewWants(event) { return }

        default:
            break
        }

        super.sendEvent(event)
    }

    /// Hand `event` to whatever is behind the panel when no view here wants it.
    /// Returns true when it was passed through and must go no further.
    private func passThroughIfNoViewWants(_ event: NSEvent) -> Bool {
        guard let contentView,
              contentView.hitTest(event.locationInWindow) == nil else {
            return false
        }

        // Pass through to windows behind by temporarily ignoring mouse events
        // and re-posting.
        let screenLocation = convertPoint(toScreen: event.locationInWindow)
        ignoresMouseEvents = true

        DispatchQueue.main.async { [weak self] in
            self?.repostMouseEvent(event, at: screenLocation)
        }
        return true
    }

    private func repostMouseEvent(_ event: NSEvent, at screenLocation: NSPoint) {
        // Convert to CGEvent coordinate system (Y from top of screen)
        guard let screen = NSScreen.main else { return }
        let screenHeight = screen.frame.height
        let cgPoint = CGPoint(x: screenLocation.x, y: screenHeight - screenLocation.y)

        let mouseType: CGEventType
        switch event.type {
        case .leftMouseDown: mouseType = .leftMouseDown
        case .leftMouseUp: mouseType = .leftMouseUp
        case .rightMouseDown: mouseType = .rightMouseDown
        case .rightMouseUp: mouseType = .rightMouseUp
        default: return
        }

        let mouseButton: CGMouseButton = event.type == .rightMouseDown || event.type == .rightMouseUp ? .right : .left

        if let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: cgPoint,
            mouseButton: mouseButton
        ) {
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}
