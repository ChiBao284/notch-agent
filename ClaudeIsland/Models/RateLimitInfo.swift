//
//  RateLimitInfo.swift
//  ClaudeIsland
//
//  Claude subscription plan usage limits, as reported by Claude Code's
//  statusLine integration ("Your usage limits" — the 5-hour and 7-day windows).
//

import Foundation

/// One rate-limit window's usage.
struct RateLimitWindow: Codable, Sendable, Equatable {
    /// 0...100 — Claude Code's own pre-calculated percentage.
    let usedPercentage: Double?
    /// Unix epoch seconds when this window resets.
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    /// How long until this window resets — "<1h", "4h", "5d". Nil when the
    /// reset time is unknown or already past.
    var timeUntilReset: String? {
        guard let resetsAt else { return nil }
        let interval = Date(timeIntervalSince1970: resetsAt).timeIntervalSinceNow
        guard interval > 0 else { return nil }
        let hours = Int(interval / 3600)
        if hours < 1 { return "<1h" }
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// e.g. " · resets 1h", for a tooltip suffix. Empty when unknown or past.
    var resetLabel: String {
        timeUntilReset.map { " · resets \($0)" } ?? ""
    }

    /// e.g. "resets in 4h" — the standalone form the usage panel shows.
    var resetsInLabel: String? {
        timeUntilReset.map { "resets in \($0)" }
    }
}

/// Plan usage across both windows Claude Code tracks. Account-wide, not
/// per-session — every session on the account reports the same numbers.
struct RateLimitInfo: Codable, Sendable, Equatable {
    let fiveHour: RateLimitWindow?
    let sevenDay: RateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}
