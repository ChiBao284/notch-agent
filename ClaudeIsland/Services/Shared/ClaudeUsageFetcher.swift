//
//  ClaudeUsageFetcher.swift
//  ClaudeIsland
//
//  Fetches real plan usage from Anthropic, the same way the Claude Code CLI does
//

import Foundation
import os.log
import Security

/// Reads the account's live 5-hour and weekly usage.
///
/// The statusLine hook also reports these numbers, but only Claude Code running
/// in a *terminal* ever invokes it — Claude Code Desktop has no status line to
/// render, so a desktop-only workflow never produced any usage data. This asks
/// Anthropic directly instead, so the readout works either way.
///
/// Auth reuses the OAuth token Claude Code already stored in the login keychain.
/// Nothing is written and no new sign-in happens; on the first read macOS asks
/// the user to allow this app access to that item.
enum ClaudeUsageFetcher {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "Usage")

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Keychain item Claude Code stores its OAuth tokens under.
    private static let keychainService = "Claude Code-credentials"

    /// Matches the CLI's own request — the endpoint is gated behind this beta.
    private static let oauthBetaHeader = "oauth-2025-04-20"

    // MARK: - Fetching

    /// Current usage, or nil when signed out, offline, or the token has expired.
    ///
    /// Returning nil is not an error worth surfacing: the caller keeps whatever
    /// it last knew rather than blanking the readout on a flaky network.
    static func fetchUsage() async -> RateLimitInfo? {
        guard let token = accessToken() else {
            logger.debug("No Claude Code OAuth token in the keychain — skipping usage fetch")
            return nil
        }

        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                // 401 means the token expired. Claude Code refreshes it in the
                // keychain the next time it runs, so the next poll recovers on
                // its own — nothing to do here but wait.
                logger.debug("Usage fetch returned HTTP \(http.statusCode, privacy: .public)")
                return nil
            }

            let payload = try JSONDecoder().decode(UsageResponse.self, from: data)
            return payload.rateLimitInfo
        } catch {
            logger.debug("Usage fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Keychain

    private static func accessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                logger.debug("Keychain read failed with status \(status, privacy: .public)")
            }
            return nil
        }

        let credentials = try? JSONDecoder().decode(StoredCredentials.self, from: data)
        return credentials?.claudeAiOauth?.accessToken
    }

    private struct StoredCredentials: Decodable {
        let claudeAiOauth: OAuth?

        struct OAuth: Decodable {
            let accessToken: String?
        }
    }
}

// MARK: - Response

/// The slice of `/api/oauth/usage` we care about.
///
/// Note the shape differs from the statusLine payload this app already handles:
/// here `utilization` is already 0...100 and `resets_at` is an ISO-8601 string,
/// where the hook sends `used_percentage` and a Unix timestamp.
private struct UsageResponse: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var asRateLimitWindow: RateLimitWindow {
            RateLimitWindow(
                usedPercentage: utilization,
                resetsAt: resetsAt.flatMap(Self.parseTimestamp)?.timeIntervalSince1970
            )
        }

        /// The API sends fractional seconds; `ISO8601DateFormatter` needs to be
        /// told about them explicitly, and older responses may omit them.
        private static func parseTimestamp(_ value: String) -> Date? {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: value) { return date }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: value)
        }
    }

    /// Nil when neither window came back, so the caller can tell "no data" from
    /// "genuinely at 0%".
    var rateLimitInfo: RateLimitInfo? {
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return RateLimitInfo(
            fiveHour: fiveHour?.asRateLimitWindow,
            sevenDay: sevenDay?.asRateLimitWindow
        )
    }
}
