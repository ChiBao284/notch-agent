//
//  ContextWindowInfo.swift
//  ClaudeIsland
//
//  A session's context window usage, as reported by Claude Code's
//  statusLine integration — authoritative, unlike deriving it from the
//  transcript ourselves: Claude Code knows the model's actual context
//  window size (200K, or 1M for extended-context sessions), which isn't
//  visible anywhere in the JSONL transcript.
//

import Foundation

struct ContextWindowInfo: Codable, Sendable, Equatable {
    /// 0...100 — Claude Code's own pre-calculated percentage.
    let usedPercentage: Double?
    /// The model's actual context window size in tokens (200000, or 1000000
    /// for extended-context sessions).
    let contextWindowSize: Int?
    /// Tokens currently in the context window (input + cache reads/writes).
    let totalInputTokens: Int?
    let totalOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case contextWindowSize = "context_window_size"
        case totalInputTokens = "total_input_tokens"
        case totalOutputTokens = "total_output_tokens"
    }

    /// e.g. "45K / 200K"
    var formatted: String {
        guard let totalInputTokens, let contextWindowSize else { return "—" }
        return "\(Self.formattedCount(totalInputTokens)) / \(Self.formattedCount(contextWindowSize))"
    }

    private static func formattedCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.0fK", Double(n) / 1_000)
        }
        return "\(n)"
    }
}
