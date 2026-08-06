//
//  ThemeManager.swift
//  ClaudeIsland
//
//  Resolves and persists the notch appearance (system / dark / light)
//

import AppKit
import Combine
import SwiftUI

/// Appearance the notch UI should use.
enum AppThemeMode: String, CaseIterable, Sendable {
    case system
    case dark
    case light

    var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon"
        case .light: return "sun.max"
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    // MARK: - Published State

    /// The mode the user picked.
    @Published var mode: AppThemeMode {
        didSet {
            guard oldValue != mode else { return }
            AppSettings.themeMode = mode
            isDark = Self.resolveIsDark(for: mode)
        }
    }

    /// The appearance actually in effect — `.system` resolved against macOS.
    @Published private(set) var isDark: Bool

    /// Whether the picker row in the settings menu is expanded.
    @Published var isPickerExpanded: Bool = false

    // MARK: - Derived

    /// Color scheme to force on the SwiftUI hierarchy, or nil to follow the system.
    var colorScheme: ColorScheme? {
        switch mode {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    /// Appearance to pin on the notch panel. Pinning it on the window is what
    /// makes the dynamic colours in `Theme.swift` resolve to the chosen theme.
    var panelAppearance: NSAppearance? {
        switch mode {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }

    /// Extra height the settings menu needs when the picker is expanded.
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        return CGFloat(AppThemeMode.allCases.count) * 32 + 8
    }

    // MARK: - Private State

    private var appearanceObserver: NSObjectProtocol?

    private init() {
        let stored = AppSettings.themeMode
        self.mode = stored
        self.isDark = Self.resolveIsDark(for: stored)

        // The system appearance can change under us — the auto light/dark
        // schedule, or the user flipping it in System Settings. Follow it so
        // `.system` stays honest.
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.mode == .system else { return }
                self.isDark = Self.resolveIsDark(for: .system)
            }
        }
    }

    deinit {
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
    }

    // MARK: - Public API

    func select(_ mode: AppThemeMode) {
        self.mode = mode
    }

    // MARK: - Resolution

    private static func resolveIsDark(for mode: AppThemeMode) -> Bool {
        switch mode {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            if let app = NSApp {
                return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }
            // Before NSApp exists, fall back to the global preference.
            return UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?
                .lowercased()
                .contains("dark") ?? false
        }
    }
}
