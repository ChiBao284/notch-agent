//
//  ClaudePermissionMode.swift
//  ClaudeIsland
//
//  Claude Code's permission modes, as reported by the `permission_mode`
//  field on every hook event.
//

import Foundation

/// A Claude Code session's current permission mode.
///
/// Raw values match the strings Claude Code itself uses (`default`,
/// `acceptEdits`, ...), so this decodes directly from the hook payload.
enum ClaudePermissionMode: String, CaseIterable, Sendable {
    case manual = "default"
    case acceptEdits
    case plan
    case auto
    case dontAsk
    case bypassPermissions

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .acceptEdits: return "Accept Edits"
        case .plan: return "Plan"
        case .auto: return "Auto"
        case .dontAsk: return "Don't Ask"
        case .bypassPermissions: return "Bypass Permissions"
        }
    }

    var icon: String {
        switch self {
        case .manual: return "pause.circle"
        case .acceptEdits: return "checkmark.circle"
        case .plan: return "list.bullet.clipboard"
        case .auto: return "bolt.circle"
        case .dontAsk: return "hand.raised.slash"
        case .bypassPermissions: return "exclamationmark.shield"
        }
    }

    /// Modes reachable mid-session via the Shift+Tab cycle, in cycle order.
    ///
    /// `bypassPermissions` and `dontAsk` are deliberately excluded — Claude
    /// Code refuses to enter either one in a session that wasn't started with
    /// it enabled, so no amount of cycling from here can ever reach them.
    static let cyclable: [ClaudePermissionMode] = [.manual, .acceptEdits, .plan, .auto]
}
