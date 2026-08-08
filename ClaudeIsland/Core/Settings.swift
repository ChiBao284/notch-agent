//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

/// How eagerly the notch expands when the cursor hovers over it.
enum HoverOpenSpeed: String, CaseIterable, Sendable {
    case instant
    case normal

    var label: String {
        switch self {
        case .instant: return "Instant"
        case .normal: return "Normal"
        }
    }

    /// How long a sustained hover must last before it opens the notch.
    var delay: TimeInterval {
        switch self {
        case .instant: return 0
        case .normal: return 1.0
        }
    }

    /// Spring response for the open animation — snappier for instant mode.
    var openAnimationResponse: Double {
        switch self {
        case .instant: return 0.2
        case .normal: return 0.42
        }
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let claudeDirectoryName = "claudeDirectoryName"
        static let themeMode = "themeMode"
        static let hoverOpenSpeed = "hoverOpenSpeed"
    }

    // MARK: - Theme

    /// Appearance for the notch UI. Defaults to following the system.
    static var themeMode: AppThemeMode {
        get {
            guard let rawValue = defaults.string(forKey: Keys.themeMode),
                  let mode = AppThemeMode(rawValue: rawValue) else {
                return .system
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.themeMode)
        }
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Hover Open Speed

    /// How quickly hovering the notch opens it. Defaults to the original
    /// 1-second-delay behavior so existing users see no change unopted-in.
    static var hoverOpenSpeed: HoverOpenSpeed {
        get {
            guard let rawValue = defaults.string(forKey: Keys.hoverOpenSpeed),
                  let mode = HoverOpenSpeed(rawValue: rawValue) else {
                return .normal
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.hoverOpenSpeed)
        }
    }

    // MARK: - Claude Directory

    /// The name of the Claude config directory under the user's home folder.
    /// Defaults to ".claude" (standard Claude Code installation).
    /// Change to ".claude-internal" (or similar) for enterprise/custom distributions.
    static var claudeDirectoryName: String {
        get {
            let value = defaults.string(forKey: Keys.claudeDirectoryName) ?? ""
            return value.isEmpty ? ".claude" : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.claudeDirectoryName)
        }
    }
}
