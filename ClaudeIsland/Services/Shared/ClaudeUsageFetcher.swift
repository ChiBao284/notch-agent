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
/// No new sign-in ever happens — but an expired access token IS refreshed
/// through Anthropic's token endpoint, the same way Claude Code itself would,
/// and the rotated pair is written back to the same keychain item so Claude
/// Code's own next refresh doesn't 401 against a token this already replaced.
/// macOS asks the user to allow this app access to that item on the first read
/// and, separately, on the first write.
actor ClaudeUsageFetcher {
    static let shared = ClaudeUsageFetcher()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "Usage")

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// Keychain item Claude Code stores its OAuth tokens under.
    private static let keychainService = "Claude Code-credentials"

    /// Matches the CLI's own request — the endpoint is gated behind this beta.
    private static let oauthBetaHeader = "oauth-2025-04-20"

    /// Claude Code's own public OAuth client id. Public-client ids (CLIs,
    /// desktop apps) are meant to ship in the clear — Anthropic's token
    /// endpoint validates the refresh_token against it, so the refresh request
    /// has to present the same id Claude Code itself would.
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// How long to sit out after a rate limit that carries no `Retry-After`.
    private static let defaultBackoff: TimeInterval = 900

    /// Set when the endpoint rate-limits us. Asking again before this only
    /// deepens the hole — the server counts rejected requests too.
    private var retryNotBefore: Date?

    // MARK: - Fetching

    /// Current usage, or nil when signed out, offline, rate-limited, or no
    /// token could be produced.
    ///
    /// Returning nil is not an error worth surfacing: the caller keeps whatever
    /// it last knew rather than blanking the readout on a flaky network.
    func fetchUsage() async -> RateLimitInfo? {
        if let retryNotBefore, Date() < retryNotBefore {
            return nil
        }

        guard let creds = Self.readStoredCredentials(), let accessToken = creds.accessToken else {
            Self.logger.debug("No Claude Code OAuth token in the keychain — skipping usage fetch")
            return nil
        }

        switch await Self.probe(accessToken: accessToken) {
        case .success(let info):
            retryNotBefore = nil
            return info

        case .rateLimited(let wait):
            retryNotBefore = Date().addingTimeInterval(wait)
            Self.logger.notice("Usage endpoint rate-limited; backing off \(Int(wait), privacy: .public)s")
            return nil

        case .otherFailure:
            return nil

        case .unauthorized:
            // The access token Claude Code minted lives about 8h; once it
            // expires, waiting no longer helps the way a 429 does — only a
            // refresh does. Without this, the readout depended on Claude Code
            // itself running again to renew its own keychain entry.
            guard let refreshToken = creds.refreshToken,
                  let refreshed = await Self.refreshAccessToken(refreshToken: refreshToken) else {
                Self.logger.debug("Access token expired and refresh was unavailable or failed")
                return nil
            }

            // Anthropic rotates the refresh_token on every use — the one we
            // just spent is now invalid server-side. Writing the new pair
            // back keeps Claude Code's OWN next refresh from 401ing against
            // a token this already replaced.
            var rotatedOAuth = creds.oauth
            rotatedOAuth["accessToken"] = refreshed.accessToken
            rotatedOAuth["refreshToken"] = refreshed.refreshToken
            rotatedOAuth["expiresAt"] = refreshed.expiresAt
            if !Self.writeStoredCredentials(account: creds.account, oauth: rotatedOAuth) {
                Self.logger.error("Refreshed Claude token but failed to write it back to the keychain")
            }

            switch await Self.probe(accessToken: refreshed.accessToken) {
            case .success(let info):
                retryNotBefore = nil
                return info
            case .rateLimited(let wait):
                retryNotBefore = Date().addingTimeInterval(wait)
                return nil
            case .unauthorized, .otherFailure:
                return nil
            }
        }
    }

    // MARK: - Probing

    /// Outcome of one `/api/oauth/usage` call against one access token.
    private enum ProbeResult {
        /// Accepted; carries whatever the endpoint reported (nil if neither
        /// window came back, which is "no data yet", not a failure).
        case success(RateLimitInfo?)
        case rateLimited(TimeInterval)
        case unauthorized
        case otherFailure
    }

    private static func probe(accessToken: String) async -> ProbeResult {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .otherFailure }

            if http.statusCode == 401 { return .unauthorized }
            if http.statusCode == 429 {
                return .rateLimited(retryAfter(from: http) ?? defaultBackoff)
            }
            guard http.statusCode == 200 else {
                logger.debug("Usage fetch returned HTTP \(http.statusCode, privacy: .public)")
                return .otherFailure
            }

            // The endpoint doesn't always signal rejection through the status
            // code — a 200 can carry an error body instead of the usage shape.
            // Checked before decoding the success shape: falling straight
            // through to that decode would fail on this body too, but read as
            // a generic parse error and never set the backoff that stops this
            // from re-asking an endpoint already refusing it.
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
               envelope.error?.type == "rate_limit_error" {
                return .rateLimited(defaultBackoff)
            }

            let payload = try JSONDecoder().decode(UsageResponse.self, from: data)
            return .success(payload.rateLimitInfo)
        } catch {
            logger.debug("Usage fetch failed: \(error.localizedDescription, privacy: .public)")
            return .otherFailure
        }
    }

    /// `Retry-After`, which the server may send as a number of seconds.
    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds > 0 else {
            return nil
        }
        return seconds
    }

    // MARK: - Refresh

    private struct RefreshedTokens {
        let accessToken: String
        let refreshToken: String
        /// Milliseconds since epoch — matches Claude Code's own keychain shape.
        let expiresAt: Int64
    }

    /// Exchanges a refresh token for a fresh pair. Mirrors the grant Claude
    /// Code's own CLI sends; returns nil on any failure (expired/revoked
    /// refresh token, network error, unexpected response) and leaves the
    /// keychain untouched.
    private static func refreshAccessToken(refreshToken: String) async -> RefreshedTokens? {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.debug("Claude token refresh failed — HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                return nil
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String,
                  let refresh = obj["refresh_token"] as? String else {
                logger.debug("Claude token refresh failed — malformed response")
                return nil
            }
            // expires_in is seconds from now; Claude Code's own keychain entry
            // stores the absolute deadline in milliseconds.
            let expiresIn = (obj["expires_in"] as? Double) ?? 28_800
            let expiresAt = Int64((Date().timeIntervalSince1970 + expiresIn) * 1000)
            return RefreshedTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
        } catch {
            logger.debug("Claude token refresh failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Keychain

    /// What was read from the credentials item: the token pair, plus enough
    /// to write a rotation back to the exact same entry.
    private struct StoredCredentials {
        let account: String?
        /// Every field Claude Code stored alongside the tokens (subscription
        /// type, scopes, …), untouched except for the three keys a refresh
        /// rotates. Kept as a raw dictionary rather than a typed model so a
        /// write-back never drops a field this app doesn't know about.
        let oauth: [String: Any]

        var accessToken: String? { oauth["accessToken"] as? String }
        var refreshToken: String? { oauth["refreshToken"] as? String }
    }

    private static func readStoredCredentials() -> StoredCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data else {
            if status != errSecItemNotFound {
                logger.debug("Keychain read failed with status \(status, privacy: .public)")
            }
            return nil
        }

        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = outer["claudeAiOauth"] as? [String: Any] else {
            return nil
        }

        return StoredCredentials(account: attributes[kSecAttrAccount as String] as? String, oauth: oauth)
    }

    /// Writes a rotated token pair back into the same keychain item, keeping
    /// every other field. Scoped to `account` too when known, so the update
    /// can't land on a different entry sharing this service name.
    @discardableResult
    private static func writeStoredCredentials(account: String?, oauth: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]) else {
            return false
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService
        ]
        if let account { query[kSecAttrAccount as String] = account }

        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecSuccess {
            logger.debug("Keychain write failed with status \(status, privacy: .public)")
            return false
        }
        return true
    }
}

// MARK: - Response

/// Matches Anthropic answering 200 with a failure body instead of the usage
/// shape — decoded ahead of `UsageResponse` so this specific case is told
/// apart from a genuine parse error.
private struct ErrorEnvelope: Decodable {
    let error: Detail?

    struct Detail: Decodable {
        let type: String?
    }
}

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
