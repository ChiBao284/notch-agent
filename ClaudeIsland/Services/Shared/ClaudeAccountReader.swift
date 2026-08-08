//
//  ClaudeAccountReader.swift
//  ClaudeIsland
//
//  Reads the signed-in account's plan from Claude Code's own config file
//

import AppKit
import Combine
import Foundation
import os.log

/// Supplies the plan badge shown beside "Claude" in the usage panel — TEAM,
/// MAX, PRO…
///
/// None of the hook or statusLine payloads carry the plan, so it comes from
/// `.claude.json`, which Claude Code writes when you sign in.
@MainActor
final class ClaudeAccountReader: ObservableObject {
    static let shared = ClaudeAccountReader()

    /// Short uppercase plan name, or nil when signed out or unreadable.
    @Published private(set) var planLabel: String?

    private static let logger = Logger(subsystem: "com.claudeisland", category: "ClaudeAccount")

    private init() {
        reload()

        // Signing in or changing plans happens outside this app entirely.
        // Re-reading on activation picks it up without watching a 60KB file.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
    }

    // MARK: - Loading

    private func reload() {
        Task.detached(priority: .utility) {
            let label = Self.loadPlanLabel()
            await MainActor.run { [weak self] in
                guard let self, self.planLabel != label else { return }
                self.planLabel = label
            }
        }
    }

    /// Config locations, newest layout first. A custom `CLAUDE_CONFIG_DIR`
    /// keeps its own `.claude.json`; the stock install leaves one in `~`.
    private nonisolated static var configCandidates: [URL] {
        [
            ClaudePaths.claudeDir.appendingPathComponent(".claude.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        ]
    }

    private nonisolated static func loadPlanLabel() -> String? {
        for url in configCandidates {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let config = try JSONDecoder().decode(ClaudeConfigFile.self, from: data)
                if let label = planLabel(for: config.oauthAccount) {
                    return label
                }
            } catch {
                logger.debug("Unreadable Claude config at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    // MARK: - Plan Naming

    private nonisolated static func planLabel(for account: ClaudeConfigFile.OAuthAccount?) -> String? {
        guard let account else { return nil }

        switch account.organizationType {
        case "claude_team": return "TEAM"
        case "claude_enterprise": return "ENTERPRISE"
        case "claude_max": return "MAX"
        case "claude_pro": return "PRO"
        default: break
        }

        // Personal accounts report a generic org type, so the seat tier is what
        // actually names the plan there: "max_20x" → MAX, "pro" → PRO.
        guard let tier = account.seatTier?.split(separator: "_").first, !tier.isEmpty else {
            return nil
        }
        return tier.uppercased()
    }
}

/// Only the fields we need — `JSONDecoder` skips the rest of the file.
///
/// Top-level rather than nested in ``ClaudeAccountReader`` so its `Decodable`
/// conformance stays off the main actor, where the decoding runs.
private struct ClaudeConfigFile: Decodable {
    let oauthAccount: OAuthAccount?

    struct OAuthAccount: Decodable {
        let organizationType: String?
        let seatTier: String?
    }
}
